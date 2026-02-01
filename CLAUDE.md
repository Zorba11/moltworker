# Project Memory

## Repository Ecosystem

```
openclaw/openclaw           # Source repo for the OpenClaw gateway binary
    |
    v  (published as `openclaw` npm package)
cloudflare/moltworker       # Upstream: Cloudflare Worker that runs OpenClaw in a Sandbox container
    |
    v  (forked)
Zorba11/moltworker          # Our fork with multi-provider support + pnpm
```

- **openclaw** npm package: The gateway binary (CLI still named `clawdbot` internally)
- **moltworker**: Cloudflare Worker that manages the Sandbox container lifecycle, proxies HTTP/WebSocket to the gateway

## Fork Setup

| Remote     | URL                                              |
|------------|--------------------------------------------------|
| `origin`   | `https://github.com/Zorba11/moltworker.git`     |
| `upstream` | `https://github.com/cloudflare/moltworker`       |

Local clone path: `/Users/zorba11/Desktop/projects/molty`

### Upstream Sync Workflow

```bash
git fetch upstream
git merge upstream/main
# resolve conflicts if any
pnpm test && pnpm run typecheck
git push origin main
```

## Multi-Provider Architecture

The Worker supports multiple AI providers simultaneously. Provider priority for the default model:

1. **Moonshot/Kimi K2.5** (via `MOONSHOT_API_KEY`) - cheapest, preferred default
2. **Anthropic/Claude** (via `ANTHROPIC_API_KEY`) - direct API
3. **AI Gateway / OpenAI** (via `AI_GATEWAY_API_KEY` + `AI_GATEWAY_BASE_URL`) - Cloudflare AI Gateway routing

### How Providers Are Configured

- `src/gateway/env.ts` (`buildEnvVars()`) maps Worker secrets to container env vars
- `start-moltbot.sh` reads those env vars and writes provider config into `~/.clawdbot/clawdbot.json`
- The gateway reads the config and connects to the configured providers

### Key Decision: skipGatewayMapping

When `MOONSHOT_API_KEY` is set and AI Gateway is NOT pointing at OpenAI, the `AI_GATEWAY_*` vars are skipped entirely. This prevents stale gateway secrets (pointing at an old moonshot endpoint) from creating a broken anthropic provider config.

## Key Files

| File | Purpose |
|------|---------|
| `src/index.ts` | Main Hono app, middleware, route mounting, catch-all proxy |
| `src/types.ts` | `MoltbotEnv` interface (all Worker secrets/bindings) |
| `src/gateway/env.ts` | `buildEnvVars()` - maps Worker secrets to container env vars |
| `src/gateway/process.ts` | Gateway process lifecycle (find, start, crash-debug) |
| `src/gateway/r2.ts` | R2 bucket mounting for persistent storage |
| `src/gateway/sync.ts` | R2 backup sync logic |
| `src/routes/debug.ts` | `/debug/*` endpoints (env, processes, logs, ws-test) |
| `src/routes/api.ts` | `/api/*` endpoints (devices, gateway management) |
| `Dockerfile` | Container image: Node 22 + openclaw@2026.1.30 + pnpm |
| `start-moltbot.sh` | Container startup: restore R2 backup, configure providers, start gateway |
| `moltbot.json.template` | Default gateway configuration template |
| `wrangler.jsonc` | Worker + Container + R2 + cron config |

## Build & Deploy

```bash
pnpm install                # Install dependencies
pnpm run build              # Build Worker + React admin UI (vite)
pnpm run typecheck          # TypeScript strict check
pnpm test                   # Run vitest tests
pnpm run deploy             # Build + deploy to Cloudflare Workers
pnpm run dev                # Vite dev server
pnpm run start              # wrangler dev (local worker)
```

## Adding a New Provider

1. Add the API key to `MoltbotEnv` in `src/types.ts`
2. Pass it through in `buildEnvVars()` in `src/gateway/env.ts`
3. Add provider config block in `start-moltbot.sh` (Node.js heredoc section)
4. Update `validateRequiredEnv()` in `src/index.ts` to accept the new key as a valid AI provider
5. Add to `/debug/env` endpoint in `src/routes/debug.ts`
6. Update README.md secrets table
7. Add tests in `src/gateway/env.test.ts`

## Container Details

- Base image: `cloudflare/sandbox:0.7.0`
- Node.js: 22.13.1 (required by openclaw)
- Gateway binary: `openclaw@2026.1.30` (symlinked as `clawdbot` for backward compat)
- Gateway port: 18789
- Config path: `/root/.openclaw/openclaw.json` (symlinked from `/root/.clawdbot`)
- Workspace: `/root/clawd`
- R2 mount: `/data/moltbot`

## Important Notes

- The CLI is still named `clawdbot` internally (upstream hasn't renamed). A symlink `clawdbot -> openclaw` is created in the Dockerfile.
- `start-moltbot.sh` uses `clawdbot gateway` to start the gateway process.
- All `wrangler secret` values are set via `pnpm exec wrangler secret put <NAME>`.
- R2 storage is optional but recommended for persistence across container restarts.
- The Dockerfile has a `CACHE_BUST` arg - bump it when changing `start-moltbot.sh` or `moltbot.json.template` to force rebuild.
