set dotenv-load := true
set shell := ["bash", "-euo", "pipefail", "-c"]

dc := "docker compose -p openclaw-local"
gw := "openclaw-gateway"
cli := "openclaw-cli"
provider := env_var_or_default("OPENCLAW_PROVIDER_ID", "custom-host-docker-internal-11434")
ctx := env_var_or_default("OPENCLAW_CONTEXT_WINDOW", "16000")
max := env_var_or_default("OPENCLAW_MAX_TOKENS", "16000")

default:
  @just --list

# run openclaw-cli in the docker environment.
oc *args:
  {{dc}} run --rm openclaw-cli {{args}}  

# Shell on the gateway container
bash-gw:
  {{dc}} exec -it {{gw}} bash

# Shell on the CLI container
bash-cli *cmd:
  {{dc}} run --rm --entrypoint bash {{cli}} -lc '{{cmd}}'  

# get docker logs (-n 200)
logs:
  {{dc}} logs --no-log-prefix --timestamps -n 200 {{gw}}

# follow docker logs
watch-logs:
  {{dc}} logs -f {{gw}}

# follow docker logs, filtering for a case-insensitive pattern (e.g. a request ID)
watch-logs-filtered pattern:
  {{dc}} logs -f {{gw}} | grep -i -E "{{pattern}}"

# Rebuild images without cache (for config changes to gateway image), then restart containers to pick up changes.
rebuild:
  {{dc}} build --no-cache
  {{dc}} up -d
  sleep 2

# Run onboarding wizard and apply config via CLI.
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

# rebuild docker images and re-run onboarding (for config changes that require image rebuild, e.g. env var changes)
reset:
  just rebuild
  just onboard

# Remove containers, images, AND VOLUMES (for a truly clean slate). Use with caution!
nuke:
  {{dc}} down -v --remove-orphans || true
  docker ps -aq --filter "name=openclaw-" | xargs -r docker rm -f || true
  docker volume ls -q | grep -E '^openclaw_' | xargs -r docker volume rm -f || true
  docker image rm -f openclaw:local || true

# Rebuild from scratch and re-run onboarding
nuke-reset:
  just nuke
  just rebuild
  just onboard

# Restart gateway and wait for health
gw-restart:
  {{dc}} restart {{gw}}
  just gateway-wait

gateway-wait:
  {{dc}} up -d {{gw}} >/dev/null
  bash -lc 'for i in {1..90}; do {{dc}} exec -T {{gw}} node dist/index.js health >/dev/null 2>&1 && exit 0 || true; sleep 1; done; echo "gateway-wait: gateway never became healthy" 1>&2; exit 1'
  just oc dashboard

# Apply idempotent config + approvals
apply:
  # Approvals file write (no restart needed, but harmless if you prefer)
  {{dc}} exec -T {{gw}} node dist/index.js approvals set --stdin < exec-approvals.json

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
update-env:
    #!/usr/bin/env bash
    set -e

    get_default() {
        local var_name=$1
        local fallback=$2
        if [ -f ".env-defaults" ]; then
            # Inside a shebang recipe, use a single $ for shell variables
            local val=$(grep "^${var_name}=" .env-defaults | cut -d'=' -f2- | sed "s/^'//;s/'$//;s/^\"//;s/\"$//")
            echo "${val:-$fallback}"
        else
            echo "$fallback"
        fi
    }

    prompt_var() {
        local var_name=$1
        local current_default=$(get_default "$var_name" "$2")
        read -p "$var_name [$current_default]: " input
        echo "${input:-$current_default}"
    }

    TOKEN=$(prompt_var "OPENCLAW_GATEWAY_TOKEN" "64-character-auth-token")
    BIND=$(prompt_var "OPENCLAW_GATEWAY_BIND" "lan")
    ORIGINS=$(prompt_var "OPENCLAW_ALLOWED_ORIGINS" '["http://127.0.0.1:18789","http://localhost:18789"]')
    PROV_ID=$(prompt_var "OPENCLAW_PROVIDER_ID" "custom-host-docker-internal-11434")
    PROV_MODEL=$(prompt_var "OPENCLAW_PROVIDER_MODEL" "gpt-oss:20b")
    ALIASES=$(prompt_var "OPENCLAW_MODEL_ALIASES" "ollama_gpt-oss:20b")
    CONTEXT=$(prompt_var "OPENCLAW_CONTEXT_WINDOW" "16000")
    MAX_TOKENS=$(prompt_var "OPENCLAW_MAX_TOKENS" "16000")

    {
        echo "COMPOSE_PROJECT_NAME=openclaw-local"
        printf "OPENCLAW_GATEWAY_TOKEN=%s\n" "$TOKEN"
        printf "OPENCLAW_GATEWAY_BIND=%s\n" "$BIND"
        printf "OPENCLAW_ALLOWED_ORIGINS='%s'\n" "$ORIGINS"
        printf "OPENCLAW_PROVIDER_ID=%s\n" "$PROV_ID"
        printf "OPENCLAW_PROVIDER_MODEL=%s\n" "$PROV_MODEL"
        printf "OPENCLAW_MODEL_ALIASES='%s'\n" "$ALIASES"
        printf "OPENCLAW_CONTEXT_WINDOW=%s\n" "$CONTEXT"
        printf "OPENCLAW_MAX_TOKENS=%s\n" "$MAX_TOKENS"
        echo ""
        echo "# satisfy upstream mounts using named volumes (NOT host paths)"
        echo "OPENCLAW_CONFIG_DIR=/DO_NOT_USE"
        echo "OPENCLAW_WORKSPACE_DIR=/DO_NOT_USE"
        echo ""
        echo "# silence Claude vars (unused)"
        echo "CLAUDE_AI_SESSION_KEY=disabled"
        echo "CLAUDE_WEB_SESSION_KEY=disabled"
        echo "CLAUDE_WEB_COOKIE=disabled"
    } > .env
