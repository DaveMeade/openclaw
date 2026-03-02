set dotenv-load := true
set shell := ["bash", "-euo", "pipefail", "-c"]

dc := "docker compose"
gw := "openclaw-gateway"
provider := env_var("OPENCLAW_PROVIDER_ID")
ctx := env_var("OPENCLAW_CONTEXT_WINDOW")
max := env_var("OPENCLAW_MAX_TOKENS")

default:
  @just --list

# ---------- health / inspection ----------
docker-check:
  @echo "Containers:"
  @docker ps -a | grep -i openclaw || echo "none"
  @echo "Volumes:"
  @docker volume ls | grep -i openclaw || echo "none"
  @echo "Images:"
  @docker images | grep -i openclaw || echo "none"

ps:
  {{dc}} ps

logs:
  {{dc}} logs --no-log-prefix --timestamps -n 200 {{gw}}

watch-logs:
  {{dc}} logs -f {{gw}}

watch-logs-filtered pattern:
  {{dc}} logs -f {{gw}} | grep -i -E "{{pattern}}"

oc *args:
  {{dc}} exec -it {{gw}} node dist/index.js {{args}}

sh:
  {{dc}} exec -it {{gw}} bash

cli *args:
  {{dc}} run --rm openclaw-cli {{args}}  

# run arbitrary shell in the CLI image (bypasses OpenClaw entrypoint)
cli-sh *cmd:
  {{dc}} run --rm --entrypoint bash openclaw-cli -lc '{{cmd}}'  

# ---------- core lifecycle ----------
nuke:
  {{dc}} down -v --remove-orphans || true
  docker ps -aq --filter "name=openclaw-" | xargs -r docker rm -f || true
  docker volume ls -q | grep -E '^openclaw_' | xargs -r docker volume rm -f || true
  docker image rm -f openclaw:local || true

rebuild:
  {{dc}} build --no-cache
  {{dc}} up -d
  sleep 2

onboard:
  # Stop gateway so onboarding/config writes don't race it
  {{dc}} stop {{gw}} || true

  # Run the interactive onboarding wizard in CLI (shares the same named volumes)
  {{dc}} run --rm openclaw-cli onboard

  # ---- provider/model sanity (ollama via custom provider) ----
  # Tell OpenClaw the model actually supports a 16k window (avoid 4096 default)
  {{dc}} run --rm openclaw-cli config set models.providers.{{provider}}.models[0].contextWindow {{ctx}}
  {{dc}} run --rm openclaw-cli config set models.providers.{{provider}}.models[0].maxTokens {{max}}

  # Store a (dummy) API key for the provider (required by the openai-completions adapter)
  # Interactive paste; ollama ignores the value but OpenClaw requires it present
  {{dc}} run --rm openclaw-cli models auth paste-token --provider {{provider}}

  # Patch config in the shared volume with correct JSON types
  {{dc}} run --rm \
    -e OPENCLAW_ALLOWED_ORIGINS="$OPENCLAW_ALLOWED_ORIGINS" \
    --entrypoint bash openclaw-cli -lc 'node -e "\
      const fs=require(\"fs\");\
      const p=\"/home/node/.openclaw/openclaw.json\";\
      const tok=process.env.OPENCLAW_GATEWAY_TOKEN||\"\";\
      if(!tok){console.error(\"OPENCLAW_GATEWAY_TOKEN missing\");process.exit(2);}\
      const raw=process.env.OPENCLAW_ALLOWED_ORIGINS||\"\";\
      if(!raw){console.error(\"OPENCLAW_ALLOWED_ORIGINS missing in container env\");process.exit(3);}\
      let origins; try{ origins=JSON.parse(raw); } catch(e){ console.error(\"OPENCLAW_ALLOWED_ORIGINS must be JSON array\"); process.exit(4);}\
      if(!Array.isArray(origins) || origins.length===0){ console.error(\"OPENCLAW_ALLOWED_ORIGINS must be non-empty JSON array\"); process.exit(5);}\
      const j=JSON.parse(fs.readFileSync(p,\"utf8\"));\
      j.gateway=j.gateway||{};\
      j.gateway.auth=j.gateway.auth||{};\
      j.gateway.remote=j.gateway.remote||{};\
      j.gateway.controlUi=j.gateway.controlUi||{};\
      j.gateway.auth.token=tok;\
      j.gateway.remote.token=tok;\
      j.gateway.controlUi.allowedOrigins=origins;\
      fs.writeFileSync(p, JSON.stringify(j,null,2));\
      console.log(\"patched openclaw.json: tokens + allowedOrigins\");\
    "'

  # Ensure exec runs on gateway (no node host)
  {{dc}} run --rm openclaw-cli config set tools.exec.host gateway

  # Start gateway
  {{dc}} up -d {{gw}}

  # Apply approvals + restart + wait
  just apply

  # Approve dashboard device pairing if any
  just devices-approve

reset:
  just rebuild
  just onboard

nuke-reset:
  just nuke
  just rebuild
  just onboard

# Restart gateway and wait for health
gw-restart:
  {{dc}} restart {{gw}}
  just gateway-wait

# Run an OpenClaw CLI command against the gateway, retrying a bit
gw-try *args:
  bash -lc 'for i in {1..20}; do {{dc}} exec -T {{gw}} node dist/index.js {{args}} >/dev/null 2>&1 && exit 0 || true; sleep 1; done; \
            echo "gw-try: failed: {{args}}" 1>&2; exit 1'

gateway-wait:
  {{dc}} up -d {{gw}} >/dev/null
  bash -lc 'for i in {1..90}; do {{dc}} exec -T {{gw}} node dist/index.js health >/dev/null 2>&1 && exit 0 || true; sleep 1; done; echo "gateway-wait: gateway never became healthy" 1>&2; exit 1'
  just oc dashboard

# ---------- idempotent config + approvals ----------
apply:
  # Approvals file write (no restart needed, but harmless if you prefer)
  {{dc}} exec -T {{gw}} node dist/index.js approvals set --stdin < exec-approvals.json

# --- token + config hygiene (assumes: dc := "docker compose", gw := "openclaw-gateway") ---

#devices-approve:
#  just gateway-wait
#  {{dc}} exec -T {{gw}} bash -lc 'node dist/index.js devices approve || true'

devices-approve:
  # The dashboard device request may not exist until you open the UI.
  # So we retry; if still nothing, we exit successfully.
  just gateway-wait
  bash -lc 'for i in {1..20}; do {{dc}} exec -T {{gw}} node dist/index.js devices approve >/dev/null 2>&1 && exit 0 || true; sleep 1; done; echo "devices-approve: no pending device (fine)."'

# Recreate gateway so it reloads .env (restart does NOT reload env)
token-refresh:
  {{dc}} up -d --force-recreate --no-deps {{gw}}
  sleep 2
  just token-sync
  just gateway-wait

token-sync:
  @just token-check && echo "token-sync: OK (already in sync)" || ( \
    echo "token-sync: fixing mismatch"; \
    {{dc}} stop {{gw}} || true; \
    {{dc}} run --rm openclaw-cli config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"; \
    {{dc}} run --rm openclaw-cli config set gateway.remote.token "$OPENCLAW_GATEWAY_TOKEN"; \
    {{dc}} up -d {{gw}}; \
    just gateway-wait \
  )

token-check:
  bash -lc '{{dc}} ps --format "{{"{{"}}.Names{{"}}"}}" | grep -q {{gw}} || exit 2; {{dc}} exec -T {{gw}} bash -lc '\''tok_env="${OPENCLAW_GATEWAY_TOKEN:-}"; [ -n "$tok_env" ] || exit 2; node -e "const fs=require(\"fs\"); const j=JSON.parse(fs.readFileSync(\"/home/node/.openclaw/openclaw.json\",\"utf8\")); const a=j.gateway?.auth?.token||\"\"; const r=j.gateway?.remote?.token||\"\"; const e=process.env.OPENCLAW_GATEWAY_TOKEN||\"\"; process.exit((a===e && r===e) ? 0 : 1);"'\''

tokens-patch:
  {{dc}} run --rm \
    -e OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
    --entrypoint bash openclaw-cli -lc 'node -e "\
      const fs=require(\"fs\");\
      const p=\"/home/node/.openclaw/openclaw.json\";\
      const tok=process.env.OPENCLAW_GATEWAY_TOKEN||\"\";\
      if(!tok){console.error(\"OPENCLAW_GATEWAY_TOKEN missing\");process.exit(2);}\
      const j=JSON.parse(fs.readFileSync(p,\"utf8\"));\
      j.gateway=j.gateway||{};\
      j.gateway.auth=j.gateway.auth||{};\
      j.gateway.remote=j.gateway.remote||{};\
      j.gateway.auth.token=tok;\
      j.gateway.remote.token=tok;\
      fs.writeFileSync(p, JSON.stringify(j,null,2));\
      console.log(\"patched tokens\");\
    "'

origins-show:
  @echo "$OPENCLAW_ALLOWED_ORIGINS"

origins-validate:
  {{dc}} run --rm \
    -e OPENCLAW_ALLOWED_ORIGINS="$OPENCLAW_ALLOWED_ORIGINS" \
    --entrypoint bash openclaw-cli -lc 'node -e "\
      const raw=process.env.OPENCLAW_ALLOWED_ORIGINS||\"\"; \
      console.log(\"raw=\", raw); \
      let v; try{ v=JSON.parse(raw); } catch(e){ console.error(\"BAD JSON\"); process.exit(2); } \
      if(!Array.isArray(v) || v.length===0){ console.error(\"NOT NONEMPTY ARRAY\"); process.exit(3); } \
      console.log(\"OK array length=\", v.length); \
    "'    

origins-check:
  {{dc}} run --rm \
    -e OPENCLAW_ALLOWED_ORIGINS="$OPENCLAW_ALLOWED_ORIGINS" \
    --entrypoint bash openclaw-cli -lc 'node -e "\
      const fs=require(\"fs\");\
      const j=JSON.parse(fs.readFileSync(\"/home/node/.openclaw/openclaw.json\",\"utf8\"));\
      console.log(\"env OPENCLAW_ALLOWED_ORIGINS=\", process.env.OPENCLAW_ALLOWED_ORIGINS||\"(missing)\");\
      console.log(\"file allowedOrigins=\", JSON.stringify(j.gateway?.controlUi?.allowedOrigins,null,2));\
    "'

origins-patch:
  {{dc}} run --rm \
    -e OPENCLAW_ALLOWED_ORIGINS="$OPENCLAW_ALLOWED_ORIGINS" \
    --entrypoint bash openclaw-cli -lc 'node -e "\
      const fs=require(\"fs\");\
      const p=\"/home/node/.openclaw/openclaw.json\";\
      const raw=process.env.OPENCLAW_ALLOWED_ORIGINS||\"\";\
      if(!raw){console.error(\"OPENCLAW_ALLOWED_ORIGINS missing\");process.exit(2);}\
      let origins; try{origins=JSON.parse(raw);}catch(e){console.error(\"OPENCLAW_ALLOWED_ORIGINS must be JSON array\");process.exit(3);}\
      if(!Array.isArray(origins)||origins.length===0){console.error(\"OPENCLAW_ALLOWED_ORIGINS must be non-empty JSON array\");process.exit(4);}\
      const j=JSON.parse(fs.readFileSync(p,\"utf8\"));\
      j.gateway=j.gateway||{};\
      j.gateway.controlUi=j.gateway.controlUi||{};\
      j.gateway.controlUi.allowedOrigins=origins;\
      fs.writeFileSync(p, JSON.stringify(j,null,2));\
      console.log(\"patched allowedOrigins:\", origins.length);\
    "'
    

# Print tokens (config + env) so you can eyeball mismatches fast
token-print-old:
  {{dc}} exec -T {{gw}} bash -lc 'node -e "const fs=require(\"fs\");const j=JSON.parse(fs.readFileSync(\"/home/node/.openclaw/openclaw.json\",\"utf8\"));console.log(\"auth=\",j.gateway?.auth?.token);console.log(\"remote=\",j.gateway?.remote?.token);console.log(\"env=\",process.env.OPENCLAW_GATEWAY_TOKEN);"'
