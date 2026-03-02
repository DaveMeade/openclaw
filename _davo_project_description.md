# OpenClaw Docker Deployment

## What This Is
A containerized OpenClaw deployment managed entirely through:
  - Docker Compose
    - project specific docker-compose.override.yml
  - A just-based lifecycle wrappers
  - Named volumes for persistent state
  - Environment-driven configuration
  - Idempotent config patching
  - The goal is a reproducible, self-healing local environment where:
    - Gateway runs as root inside container
    - Exec runs inside gateway (tools.exec.host = gateway)
    - Tokens and Control UI config are deterministic
    - Startup order is controlled

## Core Architecture
### 1. Gateway-Centric Execution
tools.exec.host = gateway

#### Meaning:
- All tool execution happens inside the gateway container. 
- No node-host container required.
- Simpler networking.
- Fewer moving parts.
- Gateway is the central runtime.

### 2. Gateway Runs as Root
- Gateway container runs as root to:
  - Avoid permission conflicts in named volumes
  - Ensure config writes succeed
  - Prevent UID/GID drift between CLI and gateway containers
  - This eliminates volume permission bugs entirely.

### 3. Named Volumes (Not Host Mounts)
- Persistent state lives in a Docker named volume: /home/node/.openclaw
  - Prevent agent interaction with host file system
  - Portable
  - Permission-safe
  - Docker-managed lifecycle
  - Avoid Windows/Linux path weirdness
  - Avoid UID mismatch headaches
- All config patching happens against this shared volume.
- The CLI container and gateway container both mount the same volume.

### 4. Environment-Driven Configuration:
- .env is the single source of truth for:
  - OPENCLAW_GATEWAY_TOKEN
  - OPENCLAW_GATEWAY_BIND
  - OPENCLAW_ALLOWED_ORIGINS
  - other runtime flags
- Important distinction:
  - .env → loaded by Just
  - The gateway reads from config file at startup — not from env.  
  - Docker Compose uses ${VAR} for service env injection
  - Containers do NOT automatically inherit all .env variables
  - Env values are explicitly passed when needed.

### 5. Control UI Allowlist
- When gateway binds non-loopback (LAN):
  - gateway.controlUi.allowedOrigins must be a non-empty JSON array
  - The value must be written into openclaw.json before gateway starts.
- Allowed origins are:
  - Stored in .env
  - Patched into config volume via Just
  - Not dependent on runtime env visibility after patch

### 6. Token Sync Model
Token is defined in .env and i patched into config file before gateway's boot via Just
- Never allowed to drift
- Lifecycle guarantees idempotent token sync.
- Lifecycle Management (Just-Based); All operations flow through just.

The following must always match:
- In the running config file:
  - gateway.auth.token
  - gateway.remote.token
- And in the .env
  - OPENCLAW_GATEWAY_TOKEN

### 7. Just Managed Lifecycle
This project is controlled entirely through just recipes.

#### Core Commands
- rebuild: Rebuild Docker images and bring containers up.
- onboard: Stops gateway → runs onboarding wizard in CLI → patches config (tokens + allowlist + tools.exec.host = gateway) → starts gateway → applies approvals → auto-approves devices.
- reset: rebuild → onboard
- nuke: Removes all Docker containers, images, and named volumes related to OpenClaw.
- nuke-reset: nuke → reset
- apply: Applies idempotent configuration (exec host, approvals, Control UI settings) and restarts gateway safely.
- devices-approve: Auto-approves any pending dashboard device pairing requests.
- token-sync: Ensures gateway.auth.token and gateway.remote.token match OPENCLAW_GATEWAY_TOKEN.