# Local Docker verification run

A full run of the project in Docker on a developer machine. It used the same images and compose file as CI, as an independent check that it works outside GitHub Actions.

- **Date:** 2026-10-07, 16:24 to 16:30 UTC
- **Commit:** `08d64a6` on `main`
- **Host:** Windows 11, Docker Desktop (engine 29.8.1, linux/amd64), Docker Compose v5.5.1
- **Result:** every step passed

| Step | Command | Result |
|---|---|---|
| 1. Build | `docker compose --profile test build app test` | Both images built: `dispatch-rules-guard:local` (app, 338 MB) and `dispatch-rules-guard:test` (with Chromium, 1.4 GB) |
| 2. App smoke test | `docker compose up -d --wait app`, then `curl` | Container healthy and 25 adjusters seeded; details below |
| 3. Acceptance suite | `docker compose --profile test run --rm test` | **331 scenarios (331 passed), 3,083 steps (3,083 passed)** in 2 min 40 s, including the headless-browser scenarios |
| 4. Load + audit | `docker compose --profile load run --rm --no-deps k6`, then `docker compose exec app bin/capacity_audit` | All 3 k6 thresholds held: **p95 23.97 ms** (budget 300 ms), 0.00% failed requests, 154/154 checks. k6 exit 0. Audit: **25 adjusters checked, 0 over capacity** |
| 5. Rule-change gate | `docker compose run --rm test ruby -Ilib bin/rule_diff --base config/dispatch_rules.json --proposed examples/dispatch_rules.proposed.json --claims examples/replay_claims.json --adjusters examples/demo_adjusters.json` | **FAIL, exit 1** (the expected result), with 3 breaches: 2 newly unassigned, 50.0% rerouted, 4 probe changes |
| Teardown | `docker compose --profile test --profile load down -v` | Containers, network and volume removed |

## App smoke test details (step 2)

The production container was run with `SECRET_KEY_BASE` set and the compose file's local tokens.

| Request | Expected | Got |
|---|---|---|
| `GET /up` | 200 | 200 |
| `POST /api/claims` with the ops token: CA auto, vehicle value $130,000 | 201, `luxury_auto`, ADJ-004 (the only luxury adjuster licensed outside TX/FL) | 201, `luxury_auto`, ADJ-004, with reason "Matched rule luxury_auto … Assigned to ADJ-004 (Devon Gray), the least utilized of the qualified adjusters with capacity (0/2 open)." |
| `POST /api/claims` with the ops token: TX auto, $3,000 | 201, `auto_fast_track` | 201, `auto_fast_track`, ADJ-001 |
| `GET /api/claims/stats` with no token | 401 | 401 |
| `POST /api/claims` with the adjuster token | 403 | 403 |
| `GET /api/claims/stats` with the adjuster token | 200 | 200, every configured queue listed |
| `GET /` (web UI work queue) | 200 | 200 |

## Reproduce it

```bash
export SECRET_KEY_BASE=$(openssl rand -hex 64)
docker compose --profile test build app test
docker compose up -d --wait app
docker compose --profile test run --rm test                   # acceptance suite
docker compose --profile load run --rm --no-deps k6           # k6 smoke (K6_PROFILE=smoke)
docker compose exec app bin/capacity_audit                    # exit 1 = an adjuster is over capacity
docker compose --profile test --profile load down -v
```

The raw output of each step was saved to `reports/local-docker/` (gitignored).
