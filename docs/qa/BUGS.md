# Bug log

Every defect found by QA, the code reviewer or the orchestrator, filed when found and closed with the fix commit and a regression test. Spec gaps that needed a decision rather than a fix are listed separately below. QA verdicts per round are in [QA_RUNS.md](QA_RUNS.md).

When the repo is on GitHub, each entry becomes an issue and the phase PR that fixes it closes it.

**Severity:** High = wrong result or the gate passing a bad change; Medium = failure under realistic conditions; Low = edge case, docs or hygiene.

| ID | Phase | Severity | Found by | Summary | Status | Fix | Regression test |
|---|---|---|---|---|---|---|---|
| BUG-001 | 2 | High | qa-engineer | A rules file that isn't valid UTF-8 crashed the gate with **exit 1** (read by CI as a policy breach) and a stack trace | Fixed | d3f5512 | `qa_defects_test.rb` |
| BUG-002 | 2 | High | qa-engineer | A `1e400` threshold loaded as Infinity, then crashed probe generation with exit 1 | Fixed | 9ac6a84 | `qa_defects_test.rb` |
| BUG-003 | 2 | High | qa-engineer | **The gate passed an off-by-one change (exit 0).** Probes were deduplicated by value, so a threshold $1 from another threshold was never probed | Fixed | d9bdf76 | `qa_defects_test.rb` |
| BUG-004 | 2 | Low | qa-engineer | A base rule and a proposed rule sharing an ID had their probes merged, which dropped the base threshold's probes | Fixed | 14ff2d5 | `boundary_probes_test.rb` |
| BUG-005 | 2 | Low | qa-engineer | `Roster#set_open_claims` could push an adjuster over capacity (99/5) | Fixed | c9fd021 | `inputs_test.rb` |
| BUG-006 | 2 | Low | qa-engineer | `loss_state eq "tx"` or `line_of_business eq "boat"` passed validation but could never match, so claims silently fell through | Fixed | 1c065c0 | `rules_config_test.rb` |
| BUG-007 | 2 | Low | qa-engineer | `examples/README.md` named the wrong states for the realistic day's stranded claims | Fixed | 559e524 | `shipped_data_test.rb` (README checked against a run) |
| BUG-008 | 2 | Medium | code-reviewer | **Gate blind spot:** deleting one of two rules that share a threshold left no probe for the claims that lost their route | Fixed | 8d512f4 | `qa_probes_test.rb` (written failing first) |
| BUG-009 | 2 | Medium | code-reviewer | The roster's internal adjuster list could be mutated from outside, past validation | Fixed | a952a13 | `inputs_test.rb` |
| BUG-010 | 3a | Medium | orchestrator (re-run), diagnosed by qa-engineer | **Flaky concurrency test:** under load SQLite returned `BusyException` after about 0.2 s instead of waiting the 5 s busy timeout. In production the same would make a dispatch return 500. Capacity was never violated | Fixed | e9c79d4 | `claim_dispatcher_test.rb` (forced BUSY is retried with the slot counted once; a 4th failure is raised with nothing written) |
| BUG-011 | 3a | High | qa-engineer | **A webhook blocked the API response for 58.8 s** (a trickling endpoint) or 21 s (a blackhole IP). The 2 s timeout applied per read, not per request | Fixed | 7cbc8cb | `webhook_deadline_test.rb` |
| BUG-012 | 3a | Medium | qa-engineer | `GET /api/claims?page=99999999999999999999` returned 500 (the SQLite offset overflowed) | Fixed | c8f7352 | `api_test.rb` |
| BUG-013 | 3a | Medium | qa-engineer | A duplicated API token silently took the last role, so a config slip could promote an adjuster token to ops | Fixed | cf1dd8f | `dispatch_settings_test.rb` |
| BUG-014 | 3a | Low | qa-engineer | A claim numbered `stats` could be created but never fetched; claim numbers with surrounding spaces were accepted | Fixed | f8bfb5e | `claim_input_test.rb` |
| BUG-015 | 3a | Low | qa-engineer | An invalid UTF-8 POST body returned an HTML 400 instead of JSON `malformed_json` | Fixed | f0bcf04 | `api_test.rb` |
| BUG-016 | 3a | Low | qa-engineer | A webhook URL like `ftp://…` booted, and every delivery then failed. A missing rules file gave a raw `Errno::ENOENT` instead of the refusal message | Fixed | e4e067b | `dispatch_settings_test.rb` |
| BUG-017 | 3a | Low | qa-engineer (noted, filed by orchestrator) | The in-process `WebhookQueue` has no size limit and delivers one at a time (each up to 2 s), so against a dead endpoint the backlog grows until recovery or exit | Deferred | — | — (to be handled by the transactional outbox, Q57) |
| BUG-018 | 3b | Low | qa-engineer | The claim form says "Enter an amount of $0 or more." for an amount that is too **large** (e.g. `99999999999999999999` in "Estimated loss"): `out_of_range` covers both negatives and values above 2^53−1 but has one message. Repro: file a claim through `/new-claim` with that amount; expected a message naming the upper limit, actual the $0-or-more message | Fixed | f611b7a | `claim_form_test.rb`, `web_ui_test.rb` |
| BUG-019 | 3b | Low | qa-engineer (noted, filed by orchestrator) | Every UI error page is rendered as the API's JSON body, so in production a browser user with an expired form token (422) or a 500 sees raw JSON instead of a page | Fixed | c506cd5 | `error_pages_test.rb` |
| BUG-020 | 3 | Medium | code-reviewer | `bin/rails` and `bin/rake` were committed with `#!/usr/bin/env ruby.exe`, so the app can't start on Linux CI or in Docker (`env: 'ruby.exe': No such file`). Missed because every run was on Windows | Fixed | 9e36d19 | `test/tools/bin_scripts_test.rb` |
| BUG-021 | 3 | Medium | code-reviewer | Production crashes at boot with an unexplained `ArgumentError` when `SECRET_KEY_BASE` is unset, before the Q9 refusal message; nothing documents the variable | Fixed | 0b18a93 | `boot_test.rb` (variable documented in `docs/CONFIGURATION.md`) |
| BUG-022 | 3 | Low | code-reviewer | Re-running `db:seed` resets each adjuster's stored `open_claims` to the file baseline, which allows over-assignment that the capacity audit can't see (it reads the counter) | Fixed | fd7e238 | `seeds_test.rb` |
| BUG-023 | 3 | Low | code-reviewer | If `ClaimDispatcher` is called inside an outer transaction, `requires_new` becomes a savepoint and the webhook is delivered before the real commit (latent; no current caller does this) | Fixed | fc831e9 | `claim_dispatcher_test.rb` |
| BUG-024 | 3 | Low | code-reviewer | CSRF is never exercised in tests (forgery protection is off in test), so removing the CSRF token from the form or the re-dispatch request leaves the suite green | Fixed | c157979 | `csrf_test.rb` |
| BUG-025 | 3 | Low | code-reviewer | The webhook deadline test's 2.5 s limit leaves 0.5 s of slack and will flake on a busy CI runner | Fixed | 44428c2 | `webhook_deadline_test.rb` (limit now 4.0 s) |
| BUG-026 | 3 | Low | code-reviewer | `DispatchSettings` test-override setters (rules, tokens, webhook) have no test-only guard, so production code could swap live rules or tokens | Fixed | ad1cdea | `dispatch_settings_test.rb` |
| BUG-027 | 3 | Medium | developer | `ErrorsController` called `String#parameterize` on Rack's binary-encoded (ASCII-8BIT) status text, which raises `ArgumentError`, so any error reaching the exceptions app under `/api` fell back to Rails' plain-text response instead of the JSON errors body | Fixed | c506cd5 | `error_pages_test.rb` (fails with the old `parameterize` call restored) |
| BUG-028 | 4 | High | code-reviewer | The CI `docker` job would fail on first push: `reports/` doesn't exist after checkout, so the rootful Docker daemon creates it as root through the compose bind mount, and the next `mkdir reports/k6` gets `Permission denied` | Fixed | d1967af | — (CI-only, verified by reading: `reports/k6` is created and made writable before any compose command) |
| BUG-029 | 4 | Medium | code-reviewer | Nightly k6 scenarios overwrite each other's artifacts (keyed by profile only), so the nightly "Stress breaking point" summary always shows the latency-injected run and never the real breaking point | Fixed | a949c49 | Per-scenario artifact names confirmed by the QA k6 run (`k6-summary-smoke-L135-…-latency500ms.json`); the CI summary's skipping of `-latency*ms` reports is CI-only, verified by reading |
| BUG-030 | 4 | Medium | code-reviewer | **The capacity audit is skipped exactly when a k6 run fails** (step order plus an After hook that skips failed scenarios), so over-assignment under a failing storm leaves no evidence | Fixed | 71cd15a, e3966f0 | QA k6 run, `@k6_pr` with `K6_APP_LATENCY_MS=500`: p95 534 ms crossed the threshold and the scenario failed, yet the audit ran before cleaning (`Capacity audit: 25 adjusters checked, 0 over capacity`; the pre-fix artifact said 0 checked). The CI `if: !cancelled()` part is CI-only, verified by reading |
| BUG-031 | 4 | Low | code-reviewer | `${SECRET_KEY_BASE:?}` in docker-compose aborts the documented local `test` and `k6` commands unless the variable is exported | Fixed | 57f7ed6 | — (Docker-only, verified by reading: `${SECRET_KEY_BASE:-}`, and the app still refuses to boot when it's empty, per BUG-021's `boot_test.rb`) |
| BUG-032 | 4 | Low | code-reviewer | A misconfigured stress run (wrong API token, so 100% 401s) is reported as a real breaking point and exits 0 | Fixed | 8b8651b, 9d7e8a6, 1578d4c | `test/tools/stress_run_test.rb` with `test/fixtures/k6/stress_summary_all_401.json` (2 failures with the check patched out) |
| BUG-033 | 4 | Low | code-reviewer | The load roster saturates about a minute into each profile and no claim ever closes, so most of a run measures the cheap at-capacity path and the storm burst barely contends for last slots | Deferred | — | — (needs a claim-close feature or a load-only roster; v2) |

## Spec gaps (decided, not defects)

| ID | Phase | Found by | Gap | Decision |
|---|---|---|---|---|
| G1 | 2 | qa-engineer | Fractional thresholds produced probe claims with impossible cent values | Q55: whole-dollar probes |
| G2 | 2 | qa-engineer | A rule with no conditions matched everything and shadowed later rules | Q55: at least one condition |
| G3 | 2 | qa-engineer | A numeric operator on a text field could never match | Q55: operator and field types must agree |
| G4 | 2 | qa-engineer | A UTF-8 BOM (as written by Windows PowerShell) was rejected | Q55: strip the BOM |
| G5 | 2 | qa-engineer | `Roster.new` and `Roster#update` skipped validation | Q55: validate both |
| — | 2 | developer | The bare demo command couldn't reproduce the brief; the 28-slot roster left 177 of 200 claims unassigned | Q53, Q54 |
| — | 2 | developer | The M1 rule as written counted an identical probe claim twice | Q56: a probe is identified by its claim |
