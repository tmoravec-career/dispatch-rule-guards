# Configuration

The web app reads its configuration from environment variables at boot and validates all of it. If anything is invalid, it **refuses to boot** with a message that names the problem (Q9, Q57). The rule-change gate (`bin/rule_diff`) takes command-line flags instead and reads none of these.

## Production

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `SECRET_KEY_BASE` | **yes** | none | Signs the session cookie that carries the web UI's CSRF token. Generate it with `bin/rails secret`. If it is unset or blank, boot stops with `refusing to boot in production: SECRET_KEY_BASE is not set`. |
| `DISPATCH_API_TOKENS` | **yes**, for API access | empty (every API request gets 401) | Comma-separated `token:role` pairs, where `role` is `ops` or `adjuster` (Q39). Example: `s3cr3t-ops:ops,s3cr3t-viewer:adjuster`. Boot stops on an unknown role, a missing role, a token containing whitespace, or a token listed twice (Q57). |
| `DISPATCH_WEBHOOK_URL` | no | unset (no webhooks are sent; deliveries are recorded as `not_configured`) | An absolute `http` or `https` URL that receives `claim.assigned` / `claim.unassigned` events (Q23, Q24). |
| `DISPATCH_WEBHOOK_SECRET` | **yes, if** `DISPATCH_WEBHOOK_URL` is set | unset | Shared secret for the `X-Dispatch-Signature` HMAC (Q45). Boot stops if a URL is set without it. |
| `DISPATCH_RULES_PATH` | no | `config/dispatch_rules.json` | The rules file. Boot stops if it is missing or invalid, and lists every error. |
| `DISPATCH_ADJUSTERS_PATH` | no | `config/adjusters.json` | The roster file loaded by `bin/rails db:seed`. Boot stops if it is missing or invalid. |
| `DISPATCH_RATE_LIMIT` | no | `600` in production, `1000000` elsewhere | Requests per token per window (Q48). Must be a positive integer. |
| `DISPATCH_RATE_WINDOW` | no | `60` | The rate-limit window in seconds. Must be a positive integer. |
| `DATABASE_PATH` | no | `storage/production.sqlite3` | The SQLite database file. |
| `RAILS_MAX_THREADS` | no | `3` (Puma), `5` (connection pool) | Puma threads, and the database connection pool size. |
| `PORT` | no | `3000` | The port Puma listens on. |
| `RAILS_FORCE_SSL` | no | off | Set to `1` to redirect to HTTPS and send HSTS when TLS isn't terminated in front of the app. |
| `RAILS_LOG_LEVEL` | no | `info` | Log level. |
| `PIDFILE` | no | unset | Where Puma writes its PID file. |

The app must run as a **single Puma process** (see `config/puma.rb`): the rate limiter, the webhook queue and the clock live in process memory.

## Development and test

- **Development:** API tokens default to `dev-ops-token:ops,dev-adjuster-token:adjuster`. `SECRET_KEY_BASE` isn't needed; Rails keeps a generated one in `tmp/local_secret.txt`.
- **Test:**
  - `DB_POOL` (default 25) sets the connection pool. The `@concurrency` scenarios need at least N + 1 connections.
  - `CI`: when set, headless Chrome starts with `--no-sandbox`.
  - `CONTRACTS=1` runs the JSON Schema contract tests in the plain engine suite.
- **Tasks:** `bin/rails dispatch:demo_claims` reads `COUNT` (default 50) and `SEED` (the generator's default seed).
