# AI Workflow Log

This repo was built by a team of role-scoped Claude Code subagents, directed by a human. Each phase is one PR, and each PR goes through the same pipeline:

```
PRODUCT_BRIEF.md (human)
      │
      ▼
product-analyst ──► acceptance criteria (Cucumber), open questions
      │                                   │
      │                    human answers ◄┘
      ▼
developer ──────► implementation + unit tests
      │
      ▼
qa-engineer ────► runs every relevant layer; PASS / FAIL with evidence
      │  FAIL → back to developer
      ▼
code-reviewer ──► APPROVE / REQUEST CHANGES
      │
      ▼
human merges
```

Agent definitions: [`.claude/agents/`](../.claude/agents/). Each role has a restricted toolset. For example, the reviewer is read-only and QA reports defects instead of fixing production code, so no single agent can write code and also sign off on it.

Below, each phase records what each agent produced and, most importantly, **what the later agents caught**.

---

## Phase 1: Acceptance criteria (spec only, no code)

**Outcome:** 166 Cucumber scenarios (340 runs once outlines expand) across 7 features, 52 decided questions, and a 161-phrase step glossary. Every expected value was independently recomputed by the reviewer.

| Step | Agent | What happened |
|---|---|---|
| 1 | product-analyst | Derived 100 scenarios from the brief alone and raised **37 open questions**, each with a proposed default. Flagged that the brief's "clicks" rule editing contradicted a view-only rules page, and that the off-by-one demo wouldn't fail the gate under the stated policy. |
| 2 | **human** | Decided: boundary-probe changes **fail the gate by default**; rules are read-only and edited by PR; accepted 35 defaults. |
| 3 | code-reviewer | Built its own throwaway simulator and recomputed every queue, adjuster, count and reroute %. **No wrong values.** Found testability traps: a `<select>` filled like a text field, a URL check that breaks after a Rails form re-render, an underspecified "run twice" step, and 7 coverage gaps. APPROVE with fixes. |
| 4 | product-analyst | Fixed all of them. Also added a rounding edge case: the report shows 33.3%, but `--max-reroute-pct 33.3` still fails because the policy compares the unrounded 33.33%. |
| 5 | **human** | Scope added from QA hiring rubrics: a paginated and filtered list endpoint, Bearer auth (401 vs 403), k6 thresholds as the only way a run fails, label-first locators, page objects with no sleeps, a GROUP BY stats endpoint, signed and de-duplicated webhooks, rate limiting (429 + `Retry-After`), storm, soak and stress profiles, currency-formatted input, and a re-dispatch confirm dialog. Deferred: adjuster out-of-office windows. |
| 6 | product-analyst | Wrote it as 4 new feature files plus `LOAD_TEST_CRITERIA.md`. |
| 7 | code-reviewer | **REQUEST CHANGES.** All values were still correct, but 3 blockers. (a) The spec allowed a **row lock** to prevent the capacity race, and **SQLite silently ignores row locks**, so that option would look safe and leave the race open. (b) The concurrency scenario assumed retry-after-losing, which the spec never required. (c) Transaction-based test cleanup would hide data from the audit subprocess and threads. Plus 10 smaller issues. |
| 8 | product-analyst | Fixed all 13. The atomic conditional `UPDATE … WHERE open_claims < capacity` with re-select became the required mechanism. |
| 9 | code-reviewer | **REQUEST CHANGES** again. The test-only race seam it had itself proposed in step 7 could **deadlock on SQLite**: a thread parked at the barrier while holding the write lock blocks the rest, or a WAL read-to-write upgrade fails with `SQLITE_BUSY_SNAPSHOT`. Also, the contract didn't tie `status` to `adjuster_id`, so `assigned` with a null adjuster would have validated. |
| 10 | product-analyst | Fixed all 5: selection runs outside any write transaction, and the status rules moved into the shared `$defs/dispatch`. |
| 11 | orchestrator | Targeted verification of the final fixes, instead of a fourth full round. |

**What the review loop bought:** three rounds found zero arithmetic errors but **two real concurrency defects** (a lock that doesn't lock, and a test that could deadlock), plus a contract hole. Both concurrency defects would have shown up later as flaky CI, if at all. Fixing them took a few lines of spec.

---

## Phase 2: Plain-Ruby engine and rule-change impact gate

**Outcome:** `lib/dispatch/` uses only the standard library (no gems, no Rails), and `bin/rule_diff` runs without Bundler. 210 unit tests run in about 0.6 s, and 102 routing and gate scenarios pass (604 steps). The demo exits 1 with exactly the three breaches the brief describes.

| Step | Agent | What happened |
|---|---|---|
| 1 | developer | Wrote tests first, then the engine, the CLI and the Cucumber steps. Proved the steps catch regressions by breaking the engine on purpose. **Stopped instead of tuning data** when the bare demo command couldn't reproduce the brief's numbers (that was the orchestrator's mistake in the done-criterion), and flagged that the 28-slot roster left 177 of 200 seeded claims unassigned, which made the gate's default run nearly blind. |
| 2 | product-analyst | Q53: the exact demo pins its own claims and roster files. Q54: a realistic 25-adjuster shipped roster, plus acceptance checks that measure it, because the analyst said its sizing was only an estimate. |
| 3 | qa-engineer | **FAIL.** D3: **the gate passed an off-by-one rule change with exit 0.** Probes were deduplicated by value, so a threshold $1 from another threshold was never probed. This came from a choice the developer had itself flagged as "left open by the spec". D1 and D2: a non-UTF-8 file and a `1e400` threshold crashed with exit 1, which CI reads as a policy breach. Mutation testing: 13 of 16 planted bugs were caught. QA committed **failing tests** for each defect. |
| 4 | orchestrator | Decided 5 spec gaps under delegation (Q55): whole-dollar probes, finite numbers only, BOM accepted, at least one condition per rule, operator and field types must agree. |
| 5 | developer | Fixed everything. **Held back one decision (G2)** because it conflicted with a QA test it isn't allowed to edit. QA changed its own test, then G2 landed. |
| 6 | qa-engineer | **Narrow FAIL.** 14 of 18 new mutants were killed, and QA added tests for 2 of the survivors. Found that probes could merge a base rule and a proposed rule sharing an ID, that a roster setter skipped validation, and that `loss_state eq "tx"` passed validation but could never match (G6). |
| 7 | code-reviewer | **APPROVE**, with findings. Confirmed the engine has no gem dependencies, replays are isolated, comparisons are strictly unrounded, the licensing guardrail has no bypass, and the engine API supports phase 3's retry after losing a race. Found **one more blind spot** (M1): delete one of two rules that share a threshold and no probe sees the claims that lost their route. Also found the roster's internal list could be mutated, past validation. |
| 8 | qa-engineer | Wrote the M1 tests first; they **failed on purpose**. |
| 9 | developer | **Stopped again.** The M1 rule as written counted an identical probe claim twice and would have changed 4 gate scenarios. It proposed defining the probe by the claim it builds. The orchestrator accepted that, and M1 landed with every feature unchanged. |

**What the loop bought:** across two QA rounds and one review, the gate went from silently passing two kinds of dangerous rule change (an adjacent-threshold off-by-one, and a deleted rule hidden by a shared threshold) to catching both, each pinned by a regression test written before the fix. The role boundaries did real work here. The developer couldn't edit QA's tests or the spec, so every conflict came back as a decision instead of a quiet workaround.
