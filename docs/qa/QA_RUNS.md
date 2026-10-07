# QA verdicts

One row per verification round. A FAIL sends the phase back to the developer, and nothing merges until QA passes and the code reviewer approves. Defects are in [BUGS.md](BUGS.md).

| Phase | Round | Date | Agent | Verdict | Defects filed | Notes |
|---|---|---|---|---|---|---|
| 2 | 1 | 2026-10-06 | qa-engineer | **FAIL** | BUG-001, 002, 003 | The gate passed an off-by-one change. Mutation testing: 13 of 16 planted bugs caught. Failing tests committed first. |
| 2 | 2 | 2026-10-06 | qa-engineer | **FAIL** (narrow) | BUG-004, 005, 006, 007 | 14 of 18 new mutants killed; QA added tests killing 2 more. No regressions. |
| 2 | review | 2026-10-06 | code-reviewer | APPROVE with findings | BUG-008, 009 | BUG-008 was a second gate blind spot, found after QA had passed it. |
| 2 | final | 2026-10-06 | orchestrator | PASS | — | 210 unit tests, 102 scenarios, both demo exit codes verified independently. |
| 3a | 1 | 2026-10-07 | qa-engineer | **FAIL** | BUG-010 to 016 | The flaky failure was reproduced (1 in 40) and classified as a SQLite locking problem under load, not a capacity race. The capacity invariant held in every run. |
