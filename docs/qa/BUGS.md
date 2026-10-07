# Bug log

Every defect found by QA, the code reviewer or the orchestrator, filed when found and closed with the fix commit and a regression test. Spec gaps that needed a decision rather than a fix are listed separately below. QA verdicts per round are in [QA_RUNS.md](QA_RUNS.md).

When the repo is on GitHub, each entry becomes an issue and the phase PR that fixes it closes it.

**Severity:** High = wrong result or the gate passing a bad change; Medium = failure under realistic conditions; Low = edge case, docs or hygiene.

| ID | Phase | Severity | Found by | Summary | Status | Fix | Regression test |
|---|---|---|---|---|---|---|---|
| BUG-001 | 2 | High | qa-engineer | A rules file that isn't valid UTF-8 crashed the gate with **exit 1** (read by CI as a policy breach) and a stack trace | Fixed | 673194f | `qa_defects_test.rb` |
| BUG-002 | 2 | High | qa-engineer | A `1e400` threshold loaded as Infinity, then crashed probe generation with exit 1 | Fixed | e6df662 | `qa_defects_test.rb` |
| BUG-003 | 2 | High | qa-engineer | **The gate passed an off-by-one change (exit 0).** Probes were deduplicated by value, so a threshold $1 from another threshold was never probed | Fixed | 58ec48a | `qa_defects_test.rb` |
| BUG-004 | 2 | Low | qa-engineer | A base rule and a proposed rule sharing an ID had their probes merged, which dropped the base threshold's probes | Fixed | de52cb3 | `boundary_probes_test.rb` |
| BUG-005 | 2 | Low | qa-engineer | `Roster#set_open_claims` could push an adjuster over capacity (99/5) | Fixed | e7c4b8e | `inputs_test.rb` |
| BUG-006 | 2 | Low | qa-engineer | `loss_state eq "tx"` or `line_of_business eq "boat"` passed validation but could never match, so claims silently fell through | Fixed | 53d9045 | `rules_config_test.rb` |
| BUG-007 | 2 | Low | qa-engineer | `examples/README.md` named the wrong states for the realistic day's stranded claims | Fixed | 310e478 | `shipped_data_test.rb` (README checked against a run) |
| BUG-008 | 2 | Medium | code-reviewer | **Gate blind spot:** deleting one of two rules that share a threshold left no probe for the claims that lost their route | Fixed | c8b443f | `qa_probes_test.rb` (written failing first) |
| BUG-009 | 2 | Medium | code-reviewer | The roster's internal adjuster list could be mutated from outside, past validation | Fixed | 4f6de98 | `inputs_test.rb` |
| BUG-010 | 3a | Medium | orchestrator (re-run), diagnosed by qa-engineer | **Flaky concurrency test:** under load SQLite returned `BusyException` after about 0.2 s instead of waiting the 5 s busy timeout. In production the same would make a dispatch return 500. Capacity was never violated | Fixed | d19e89d | `claim_dispatcher_test.rb` (forced BUSY is retried with the slot counted once; a 4th failure is raised with nothing written) |
| BUG-011 | 3a | High | qa-engineer | **A webhook blocked the API response for 58.8 s** (a trickling endpoint) or 21 s (a blackhole IP). The 2 s timeout applied per read, not per request | Fixed | c7e4226 | `webhook_deadline_test.rb` |
| BUG-012 | 3a | Medium | qa-engineer | `GET /api/claims?page=99999999999999999999` returned 500 (the SQLite offset overflowed) | Fixed | 71760e1 | `api_test.rb` |
| BUG-013 | 3a | Medium | qa-engineer | A duplicated API token silently took the last role, so a config slip could promote an adjuster token to ops | Fixed | 1b0d6e5 | `dispatch_settings_test.rb` |
| BUG-014 | 3a | Low | qa-engineer | A claim numbered `stats` could be created but never fetched; claim numbers with surrounding spaces were accepted | Fixed | 827c383 | `claim_input_test.rb` |
| BUG-015 | 3a | Low | qa-engineer | An invalid UTF-8 POST body returned an HTML 400 instead of JSON `malformed_json` | Fixed | 42ec488 | `api_test.rb` |
| BUG-016 | 3a | Low | qa-engineer | A webhook URL like `ftp://…` booted, and every delivery then failed. A missing rules file gave a raw `Errno::ENOENT` instead of the refusal message | Fixed | d8cdca5 | `dispatch_settings_test.rb` |
| BUG-017 | 3a | Low | qa-engineer (noted, filed by orchestrator) | The in-process `WebhookQueue` has no size limit and delivers one at a time (each up to 2 s), so against a dead endpoint the backlog grows until recovery or exit | Deferred | — | — (to be handled by the transactional outbox, Q57) |
| BUG-018 | 3b | Low | qa-engineer | The claim form says "Enter an amount of $0 or more." for an amount that is too **large** (e.g. `99999999999999999999` in "Estimated loss"): `out_of_range` covers both negatives and values above 2^53−1 but has one message. Repro: file a claim through `/new-claim` with that amount; expected a message naming the upper limit, actual the $0-or-more message | Open | — | — |

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
