# Playwright MCP sidecar

Phase 7 of the 2026-04 migration adds `@playwright/mcp` as an
**operator-facing** companion to the Rails-managed Playwright runtime.
The sidecar runs as a separate Node process and lets external MCP
clients (Claude Desktop, Devin, the MCP Inspector, etc.) drive Chromium
through a structured tool protocol while sharing the *same per-account
persistent profile dir* that production jobs use.

This is a tool for **debugging and AI-assisted sessions**. It is not
called from any Sidekiq job, controller, or the `Instagram::Client`
facade. Nothing on the production hot path depends on it.

## What it gives you

- Navigate the live Instagram session from an MCP client:
  `browser_navigate`, `browser_click`, `browser_type`, `browser_snapshot`,
  etc.
- Drive workflows interactively from a Claude/Devin conversation using
  the account's real logged-in cookies.
- Record traces + screenshots via the MCP `--trace` / `--save-trace`
  options without changing any Ruby code.

Because the sidecar opens the same `storage/browser_sessions/<id>/`
profile as the Rails app, **pause any Sidekiq worker touching that
account before starting a session**. Chromium's on-disk profile lock
will reject two concurrent openers.

## Install

One-time, already landed in `package.json`:

```bash
yarn add --dev @playwright/mcp@0.0.70
```

The binary lands at `node_modules/.bin/playwright-mcp`. Override the
path via `PLAYWRIGHT_MCP_CLI_PATH` for containerised layouts.

## Start / stop / status

Rake tasks match the `ai:nvidia:*` pattern:

```bash
# Start the sidecar for a given account (default port 8931, headful)
bin/rails playwright:mcp:start ACCOUNT=42

# Override host/port/transport/headless
bin/rails playwright:mcp:start ACCOUNT=42 PORT=8932 HOST=0.0.0.0 HEADLESS=true

# Start in stdio transport mode (for MCP clients that launch the server
# themselves; rake prints the command + args to register)
bin/rails playwright:mcp:start ACCOUNT=42 TRANSPORT=stdio

# Current state
bin/rails playwright:mcp:status ACCOUNT=42

# Stop (graceful TERM, escalates to KILL after 5 s)
bin/rails playwright:mcp:stop ACCOUNT=42
```

State lives at `tmp/playwright_mcp/<account_id>.json` — PID, sse_url,
log_path, user_data_dir. Delete the file and restart if you lose track.

## MCP client wiring

Example output from `rake playwright:mcp:start`:

```
Started Playwright MCP sidecar for account 42 (brooklyn_cafe).
  pid:        53296
  transport:  sse
  mcp_url:    http://127.0.0.1:8931/mcp (preferred; streamable HTTP)
  sse_url:    http://127.0.0.1:8931/sse (legacy SSE transport)
  user_data:  storage/browser_sessions/42
  log:        log/playwright_mcp_42.log

Configure your MCP client with:
  {"mcpServers":{"playwright":{"url":"http://127.0.0.1:8931/mcp"}}}
```

- **Claude Desktop:** drop the `{"mcpServers": {...}}` snippet into
  `~/Library/Application Support/Claude/claude_desktop_config.json`
  (macOS) or equivalent, then restart Claude.
- **Devin / Claude CLI:** point the client at `mcp_url` (modern) or
  `sse_url` (legacy) — the server publishes both on the same port.
- **stdio clients:** use `TRANSPORT=stdio` when starting; the rake task
  prints the command + args to register in your client config.

## Profile sharing + safety

- The sidecar launches Chromium against
  `storage/browser_sessions/<account_id>/`, which is the same directory
  `Instagram::Browser::AccountContext` opens for production jobs.
- Chromium profile locks are per-process; starting the sidecar while a
  Sidekiq worker is running the same account will make one of the two
  fail with `Playwright::Error("browser is already running")`. The
  Rails-side `SessionRecoverySupport` will retry the job; the MCP
  client will see an immediate failure.
- Recommended ops flow:
  1. Pause the account (turn off `continuous_processing_enabled`, or
     stop the specific Sidekiq worker class)
  2. `rake playwright:mcp:start ACCOUNT=...`
  3. Debug interactively from the MCP client
  4. `rake playwright:mcp:stop ACCOUNT=...`
  5. Re-enable the account

## Extra MCP flags

Pass through via `extra_args` when instantiating
`Instagram::Browser::McpBridge` directly, e.g. in a Rails console:

```ruby
bridge = Instagram::Browser::McpBridge.new(
  account: InstagramAccount.find(42),
  port: 8933,
  headless: true,
  extra_args: ["--caps", "vision,pdf", "--save-trace", "--output-dir", "tmp/mcp_traces/42"]
)
bridge.spawn!
```

Everything after `--user-data-dir` is under operator control; see
`node node_modules/.bin/playwright-mcp --help` for the full catalogue.
Common useful flags:

- `--caps vision,pdf,devtools` — enable richer tool capabilities
- `--save-trace` + `--output-dir` — persist Playwright traces
- `--blocked-origins` / `--allowed-origins` — scope what the MCP client
  can navigate to
- `--viewport-size 1440,1024` — pin viewport

## Not wired into production

Deliberate design choice. `McpBridge` is a standalone service class; no
Rails initializer boots it, no job enqueues it, and no controller
spawns it. The rake tasks are the single operator entry point so the
sidecar's lifecycle stays out of automated flows.

See also:
- `docs/operations/browser-sessions.md` — the profile dir layout the
  sidecar shares with production.
- `docs/architecture/nvidia-provider.md` — the AI-side of the migration,
  complementary but orthogonal to MCP.
