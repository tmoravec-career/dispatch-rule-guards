# Dispatch Rules Guard

**A claims dispatch engine, and a CI gate that catches a bad routing-rules change before it reaches adjusters. It was built end to end by a team of role-scoped AI agents that I directed.**

Claims platforms let business users change routing rules without code. That's the selling point, and it's also a quality risk: a rules edit skips code review and CI, so it can quietly misroute claims or leave them with no adjuster. This repo is a small dispatch engine plus the test tooling I'd put around it.

It's also a record of **how I use AI to develop and test**. I wrote one document, the [product brief](docs/PRODUCT_BRIEF.md). Everything else (spec, code, tests, CI) came from five agents with separate roles, each checking the others' work, with me making the product calls.

| | |
|---|---|
| Tests | **675 in all**: 331 Cucumber scenarios (3,083 steps, written before any code), 228 engine unit tests (about 0.6 s, no database), 83 Rails app tests, 24 tooling tests and 9 k6 load scenarios |
| Bugs found by the agents | **33**: 31 fixed, each with a regression test, and 2 deferred. See the [bug log](docs/qa/BUGS.md) |
| QA and review verdicts | Every phase got at least one FAIL from QA or REQUEST CHANGES from the reviewer before it passed. See the [QA rounds](docs/qa/QA_RUNS.md) |
| Product decisions | 59, each recorded with who decided it. See [decided questions](docs/specs/OPEN_QUESTIONS.md) |

Start with **[docs/AI_WORKFLOW.md](docs/AI_WORKFLOW.md)**: what each agent did in each phase, and what the later agents caught.

---

## How it was built

```
PRODUCT_BRIEF.md (human)
   → product-analyst   acceptance criteria + open questions
   → human             answers the questions, adds scope
   → developer         implementation + unit tests
   → qa-engineer       tries to break it, files bugs, writes failing tests first
   → code-reviewer     read-only review; catches what tests can't
   → human             merges
```

The agent definitions are in [`.claude/agents/`](.claude/agents/). Each role's tools are limited, so no single agent can both write code and sign off on it:

- The **reviewer is read-only**.
- **QA can add tests but can't change production code.**
- The **developer can't edit the spec or QA's tests.** When its code conflicted with either, it had to stop and report the conflict, so each one ended in a recorded decision rather than a silent workaround.

Some things this caught, which a single agent writing and checking its own code would likely have missed:

- **The gate passed an off-by-one rule change.** It exited 0 when a threshold sat $1 away from another. QA found it with a failing test before the fix (BUG-003).
- **A second blind spot in the gate:** deleting one of two rules that share a threshold went unnoticed. The code reviewer found it after QA had passed the phase (BUG-008).
- **The spec allowed a row lock that SQLite silently ignores.** It looked like protection against over-assigning an adjuster and wasn't. The reviewer caught it before any code existed.
- **A webhook blocked API responses for 58 seconds** despite a "2 s timeout", because the timeout applied per read (BUG-011).
- **A 1-in-40 flaky test** that QA traced to SQLite returning "database is locked" under load instead of waiting (BUG-010).
- **`bin/rails` was committed with a Windows-only shebang**, so the app could never start on Linux CI (BUG-020).

## The problem the gate catches

Ops asks: *"Lower the luxury-vehicle threshold from $100k to $60k."* In the same edit, someone changes a `gte` to `gt`. Both lines look harmless in a diff:

```diff
-  { "field": "estimated_loss", "op": "gte", "value": 50000 }
+  { "field": "estimated_loss", "op": "gt",  "value": 50000 }
-  { "field": "vehicle_value",  "op": "gte", "value": 100000 }
+  { "field": "vehicle_value",  "op": "gte", "value": 60000 }
```

The gate replays claims through the old and new rules and also probes every threshold at value−1, value and value+1:

```bash
ruby -Ilib bin/rule_diff --base config/dispatch_rules.json \
                         --proposed examples/dispatch_rules.proposed.json \
                         --claims examples/replay_claims.json \
                         --adjusters examples/demo_adjusters.json
```

It **exits 1**, with three policy breaches:

| Policy | Limit | Actual | Why |
|---|---|---|---|
| Newly unassigned claims | 0 | 2 | The luxury queue overflows the only luxury adjuster licensed outside TX/FL |
| Rerouted claims | 10% | 50.0% | Half the day's claims change queue |
| Boundary probe changes | 0 | 4 | Includes the off-by-one: a $50,000 CAT claim no longer reaches `cat_large_loss` |

On a pull request, CI posts this report as a sticky comment and fails the check. More examples are in [examples/README.md](examples/README.md).

## How dispatch works

1. **Route:** rules run in priority order, and the first match picks the queue and the required skills. If nothing matches, the claim goes to `general_intake`.
2. **Qualify:** an adjuster must be active, **licensed in the loss state** and hold every required skill. Licensing is enforced by the engine itself, so no rules edit can turn it off.
3. **Balance:** the qualified adjuster with the lowest utilization wins, with ties broken by ID.
4. **Claim a slot atomically:** a conditional `UPDATE … WHERE open_claims < capacity` claims the slot; if it loses a race, the dispatcher re-selects. Concurrent dispatches can never over-assign.
5. **Explain and notify:** every result carries a reason code. A signed webhook goes out after commit, with an overall 2 s deadline, and never blocks routing.

The engine (`lib/dispatch/`) is plain Ruby with no gems. Rails is a thin layer over it, which is why the gate runs in CI without booting the app.

## Running it

**Engine tests and the gate (Ruby 3.3, no bundle needed):**
```bash
ruby -Ilib -e 'Dir["test/dispatch/**/*_test.rb", "test/tools/**/*_test.rb"].each { |f| require "./#{f}" }'
ruby -Ilib bin/rule_diff --base config/dispatch_rules.json --proposed examples/dispatch_rules.proposed.json
```

**The app and the acceptance suite:**
```bash
bundle install
bin/rails db:prepare                     # creates the DB and seeds 25 adjusters
bin/rails server                         # http://localhost:3000
bundle exec cucumber                     # 331 scenarios (UI, API, contracts, gate)
bundle exec cucumber --tags @k6_pr       # k6 smoke plus capacity audit (needs k6)
```

**Docker** (these commands were verified on a local run; see [docs/LOCAL_DOCKER_RUN.md](docs/LOCAL_DOCKER_RUN.md)):
```bash
export SECRET_KEY_BASE=$(openssl rand -hex 64)
docker compose up -d --wait app                          # http://localhost:3000
docker compose --profile test run --rm test              # Cucumber in a container
docker compose --profile load run --rm --no-deps k6      # k6 smoke against the running app
docker compose exec app bin/capacity_audit               # exit 1 = an adjuster is over capacity
docker compose --profile test --profile load down -v
```

Configuration is documented in [docs/CONFIGURATION.md](docs/CONFIGURATION.md). The app refuses to boot on invalid config.

## CI

| Job | When | What fails it |
|---|---|---|
| Engine tests | every push and PR | any failure; runs first, no bundle |
| Contract tests | every push and PR | any failure, **or any skipped contract test** |
| App tests | every push and PR | any failure |
| Acceptance (Cucumber) | every push and PR | any failure; JUnit uploaded |
| k6 smoke + capacity audit | every push and PR | p95 ≥ 300 ms, ≥ 1% errors, < 99% checks, or any adjuster over capacity |
| Docker | every push and PR | build or compose smoke failure |
| Rule-change gate | PRs | a newly stranded claim, > 10% rerouted, or any boundary-probe change |
| Nightly | schedule or manual | load, storm, soak and stress profiles; 3× flake hunt; any flaky test |

The CI jobs and the Docker build were written and reviewed on a machine with neither Docker nor a GitHub remote, so at first they were checked only by code review. Both have since been verified by running:
- **On GitHub:** CI passed every job on its first real run.
- **Locally in Docker:** the image build, a production-container smoke test, all 331 scenarios, k6 smoke (p95 24 ms) with a clean capacity audit, and the gate correctly failing the demo change. See [docs/LOCAL_DOCKER_RUN.md](docs/LOCAL_DOCKER_RUN.md).

[AI_WORKFLOW.md](docs/AI_WORKFLOW.md) records what was verified when, and how.

## Known limits (v1)

- **Single process.** The rate limiter, webhook queue and clock live in memory, so it runs one Puma process.
- **Webhooks** are delivered once, with no retries. A transactional outbox is the next step (BUG-017).
- **Load profiles** fill every adjuster within about a minute, because claims are never closed. Most of a long run therefore measures the "already full" path (BUG-033).
- **SQLite** keeps the demo self-contained. The capacity logic is written so a move to Postgres changes the locking, not the design.

## Layout

```
docs/PRODUCT_BRIEF.md    the only human-written spec
docs/AI_WORKFLOW.md      phase-by-phase record of what each agent did and caught
docs/specs/              decided questions (Q1–Q59), step glossary, load-test criteria
docs/qa/                 bug log and QA verdicts
.claude/agents/          the five role definitions
features/                Cucumber acceptance criteria, steps, page objects
lib/dispatch/            plain-Ruby engine and rule-change gate
app/                     Rails layer: API, UI, dispatcher, webhooks
bin/rule_diff            the gate CLI
load/k6/                 k6 profiles; bin/stress_run reports the breaking point
script/flake_report.rb   labels each test stable, flaky or broken across runs
.github/workflows/ci.yml the pipeline
```
