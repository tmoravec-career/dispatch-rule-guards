# Decided questions: phase 1 acceptance criteria

These started as the real ambiguities in `docs/PRODUCT_BRIEF.md`. **Every question is now decided** by the product owner (Tim Moravec, 2026-10-06).

- **Q1–Q37 (the original brief):**
  - 35 defaults accepted as written.
  - Q30 (boundary-probe policy) **changed**.
  - Q34 (rules editing) **confirmed**.
  - Q21 (no auth) **superseded** by Q39.
- **Review follow-ups:** under Q29 (probe from the proposed rule) and Q32 (reroute % rounding), both **accepted**. Review clarifications that don't change a decision are marked *Clarified per review*.
- **Scope additions:**
  - Q38–Q42 (first batch): list endpoint, auth, load criteria, locator strategy, page objects.
  - Q43–Q51 (second batch): stats, status-code invariant, webhook integrity, rate limiting, load profiles, money input, re-dispatch confirmation.
  - All are marked "Decision: added".
- **Deferred:** Q52.
- **Phase 2 decisions:** Q53 (the canonical demo command) and Q54 (the shipped roster for seeded runs), marked "Decision: analyst default, delegated by Tim".

Where a scope addition needed details the request didn't give, the detail is stated in the question as part of the decided spec and labelled *analyst detail*. The feature files in `features/` encode all of it.

---

## A. Claim data model

### Q1. What are the claim fields and their types?
The brief names the routing fields but not their types, which fields are required, or which values are allowed.
**Proposed default:**

| Field | Type | Required | Allowed values |
|---|---|---|---|
| `claim_number` | string, ≤ 32 chars | yes | unique |
| `line_of_business` | string enum | yes | `auto`, `property`, `liability` |
| `estimated_loss` | integer whole dollars | yes | ≥ 0 |
| `vehicle_value` | integer whole dollars | no (null) | ≥ 0 |
| `cat_event` | boolean | no, default `false` | `true` / `false` |
| `loss_state` | string | yes | uppercase USPS code: 50 states + DC |

Money is in whole dollars, so ±1 in boundary probes means ±$1.
*Affects:* `api_dispatch` 422 outlines, `work_queue` form validation.

**Decision:** accepted default, Tim, 2026-10-06.

### Q2. Are unknown fields in an API request rejected or ignored?
**Proposed default:** rejected with 422 `unknown_field`. This matches the rules-config strictness: a typo like `vehicle_val` should not silently route a luxury car to standard.

**Decision:** accepted default, Tim, 2026-10-06.

### Q3. What does a condition do when the claim doesn't have that field (e.g. `vehicle_value` on a property claim)?
**Proposed default:** the condition is false. The rule doesn't match, and there's no error.
*Affects:* `dispatch_routing`, "A condition on a field the claim does not have…".

**Decision:** accepted default, Tim, 2026-10-06.

### Q4. Are string comparisons case-sensitive?
**Proposed default:** yes. The API rejects lowercase states (`"tx"` → 422), so the engine never sees them.

**Decision:** accepted default, Tim, 2026-10-06.

## B. Rules config

### Q5. Does a lower priority number mean "evaluated first"?
**Proposed default:** yes. Priority 10 beats priority 20.

**Decision:** accepted default, Tim, 2026-10-06.

### Q6. Exact rules JSON shape?
**Proposed default:** `{"rules":[{"id","priority","conditions":[{"field","op","value"}],"queue","required_skills":[]}]}`. No other keys are allowed at any level.

**Decision:** accepted default, Tim, 2026-10-06.

### Q7. Which fields can a condition reference?
**Proposed default:** only the five routing fields: `line_of_business`, `estimated_loss`, `vehicle_value`, `cat_event`, `loss_state`. Anything else is `unknown_field`.

**Decision:** accepted default, Tim, 2026-10-06.

### Q8. Operator/type rules. Is the string `"100000"` a valid threshold? Are floats valid?
**Proposed default:**
- `gt`/`gte`/`lt`/`lte` need a JSON number. A numeric-looking string, `null` or a boolean is `non_numeric_threshold`. Floats are accepted.
- `in` needs a non-empty array, otherwise `invalid_value`.
- `eq` takes any scalar.
- There's no `neq`/`not_in` in v1.

**Decision:** accepted default, Tim, 2026-10-06.

### Q9. What validation error codes exist, and what happens to a partly valid config?
**Proposed default:**
- Codes: `unknown_field`, `unknown_operator`, `non_numeric_threshold`, `duplicate_priority`, `duplicate_rule_id`, `missing_field`, `invalid_value`. Each has a JSON path, e.g. `rules[1].conditions[0].op`.
- **All** errors are reported together, and the whole config is rejected (nothing is partially loaded).
- The web app refuses to boot with an invalid config. The gate exits 2.

**Decision:** accepted default, Tim, 2026-10-06.

### Q10. Are duplicate rule IDs an error? (The brief only lists duplicate priorities.)
**Proposed default:** yes, `duplicate_rule_id`. Reports refer to rules by ID, so IDs must be unique.

**Decision:** accepted default, Tim, 2026-10-06.

### Q11. How is "no rules config can turn licensing off" enforced?
**Proposed default:** licensing lives in the engine, not in config. The strict schema rejects any attempt to add a key such as `enforce_licensing`, `ignore_licensing` or a per-rule `licensed_states` as `unknown_field`.

**Decision:** accepted default, Tim, 2026-10-06.

### Q12. Is an empty rule set valid?
**Proposed default:** yes. Everything falls through to `general_intake`.

**Decision:** accepted default, Tim, 2026-10-06.

## C. Qualification, capacity, balancing

### Q13. What skills does `general_intake` require?
**Proposed default:** none. Any active, licensed adjuster with capacity can take it. Licensing is still enforced.

**Decision:** accepted default, Tim, 2026-10-06.

### Q14. Do inactive adjusters count as "qualified" when choosing the unassigned reason?
**Proposed default:** no. Inactive adjusters are not qualified at all.
- If the only licensed and skilled adjusters are inactive, the reason is `no_qualified_adjuster`.
- If active qualified adjusters are full and an inactive one has room, the reason is `qualified_adjusters_at_capacity`.

**Decision:** accepted default, Tim, 2026-10-06.

### Q15. What are the reason code names?
**Proposed default:** `assigned`, `no_qualified_adjuster`, `qualified_adjusters_at_capacity`. Fall-through is not a reason code. It shows as `matched_rule: null` with queue `general_intake`.

**Decision:** accepted default, Tim, 2026-10-06.

### Q16. How is utilization defined, and how are ties compared?
**Proposed default:** `open_claims / capacity`, compared as **exact rationals**, so 1/3 ties with 2/6. Ties break on adjuster ID ascending, as strings. IDs are zero-padded (`ADJ-001`), so string order equals numeric order.

**Decision:** accepted default, Tim, 2026-10-06.

### Q17. How is an adjuster with `capacity: 0` treated?
**Proposed default:** qualified but permanently at capacity, so it contributes to `qualified_adjusters_at_capacity`. (There's no scenario for this yet.)

**Decision:** accepted default, Tim, 2026-10-06.

### Q18. Where does `open_claims` come from in the app?
**Proposed default:** it's a stored counter on the adjuster. Seed data sets it (the baseline workload), assignment increments it, and re-dispatch decrements the previous assignee before re-routing. Closing claims is out of scope for v1. The k6 capacity audit checks the counter never exceeds capacity.

**Decision:** accepted default, Tim, 2026-10-06.

### Q19. What does re-dispatch do?
**Proposed default:** it releases the current assignment, re-runs routing with the **current** rules and roster, appends to the claim's dispatch history, and emits a new webhook with a new `event_id` even if the outcome didn't change.

**Decision:** accepted default, Tim, 2026-10-06.

## D. REST API

### Q20. Which endpoints and status codes?
**Proposed default:**

| Request | Success | Errors |
|---|---|---|
| `POST /api/claims` (create + dispatch) | **201**, even when unassigned, because that's a valid outcome | 400 malformed JSON, 409 duplicate `claim_number`, 415 non-JSON content type, 422 invalid/missing/unknown fields |
| `GET /api/claims/:claim_number` | 200 | 404 |
| `POST /api/claims/:claim_number/dispatch` (re-dispatch) | 200 | 404 |

Error body: `{"errors":[{"field": "...", "code": "..."}]}`. All field errors are reported together. Codes: `missing`, `inclusion`, `invalid_value`, `not_an_integer`, `out_of_range`, `not_a_boolean`, `unknown_field`, `malformed_json`, `duplicate_claim_number`, `not_found`. (`not_a_number` was dropped; see Q50.)

Money fields (`estimated_loss`, `vehicle_value`), consistent with Q50:

| Input | Code |
|---|---|
| any JSON **string** (`"lots"`, `"12000"`, `"$1,200"`), boolean, array or object | `invalid_value` |
| a JSON number with a fractional part (`12000.5`) | `not_an_integer` |
| a negative integer | `out_of_range` |
| `null` or absent in the **required** `estimated_loss` | `missing` |
| `null` or absent in the optional `vehicle_value` | accepted, no value |

**Decision:** accepted default, Tim, 2026-10-06.

*Since extended by later decisions:*
- The list (Q38) and stats (Q43) endpoints.
- 401/403 (Q39) and 429 (Q48) on every endpoint.
- The `invalid_value` code for any non-number in a money field: strings, booleans, arrays and objects (Q50).
- The status/body invariant (Q44).

### Q21. Does the API need authentication?
**Proposed default:** no, not for this demo product.

**Decision:** accepted default, Tim, 2026-10-06. **Superseded by Q39** (added, Tim, 2026-10-06): the API now requires Bearer tokens. The web UI stays unauthenticated.

### Q22. Should claims be addressed by `claim_number` or by an internal ID in URLs?
**Proposed default:** `claim_number`.

**Decision:** accepted default, Tim, 2026-10-06.

## E. Webhook

### Q23. What is the webhook payload shape (the contract)?
**Proposed default** (`contracts/claim_dispatched.schema.json`, `additionalProperties: false` at every level):
```json
{
  "event": "claim.assigned | claim.unassigned",
  "event_id": "uuid",
  "occurred_at": "ISO-8601 date-time",
  "claim":    { "claim_number", "line_of_business", "estimated_loss", "vehicle_value|null", "cat_event", "loss_state" },
  "dispatch": { "status", "queue", "matched_rule|null", "adjuster_id|null", "reason_code", "reason" }
}
```
Conditional rules (as amended per review):
- **Where the definitions live:** the schema puts the `claim` and `dispatch` objects under **`$defs`** (`$defs/claim`, `$defs/dispatch`), each with `additionalProperties: false`. The top-level `claim` and `dispatch` properties are `$ref`s to them, and `contracts/claim_resource.schema.json` reuses the same `$defs` (Q38).
- **In `$defs/dispatch`**, keyed on `dispatch.status` (`if`/`then`):
  - `status: "assigned"` requires `adjuster_id` to be a string and `reason_code` to be `assigned`.
  - `status: "unassigned"` requires `adjuster_id` to be null and `reason_code` to be `no_qualified_adjuster` or `qualified_adjusters_at_capacity`.

  Because these rules live in `$defs/dispatch`, **both** the webhook and claim-resource contracts enforce them.
- **On the webhook envelope only:** `event` must agree with the status: `claim.assigned` ⇔ `dispatch.status = "assigned"`, and `claim.unassigned` ⇔ `"unassigned"`.

**Decision:** accepted default, Tim, 2026-10-06. Conditionals moved into `$defs/dispatch` per review, 2026-10-06.

*Clarified per review (2026-10-06):* `occurred_at` is declared `"format": "date-time"`, and contract tests must validate with format assertion turned on. Many JSON Schema validators treat `format` as annotation-only by default. Without this, the `occurred_at = "yesterday"` negative example would pass vacuously.

*Updated by Q45–Q47 (added, Tim, 2026-10-06):*
- The payload gains a required top-level `"sequence"`: an integer ≥ 1, per claim, starting at 1 and incrementing by 1 for each event about that claim.
- `occurred_at` is UTC with millisecond precision (`2026-10-06T09:00:05.000Z`).
- Every delivery carries the HTTP header `X-Dispatch-Signature: sha256=<hex HMAC-SHA256 of the raw body>`. The header is part of the delivery contract, not the JSON Schema.
- *Per review:* the schema declares `claim` and `dispatch` under `$defs`, each with `additionalProperties: false` and with the status conditionals above, and `contracts/claim_resource.schema.json` reuses them by `$ref` (Q38).

### Q24. What are the delivery semantics?
**Proposed default:**
- One attempt, made after the dispatch is committed, with a short timeout (2 s). There are no retries in v1.
- Each attempt is recorded as `delivered` or `failed` against the claim.
- If no webhook URL is configured, nothing is sent and nothing fails. *Covered by:* `api_dispatch`, "With no webhook URL configured…".

"Never blocks routing" means the API still returns its normal status, and the assignment and capacity changes stand.

**Decision:** accepted default (no retries in v1), Tim, 2026-10-06.

## F. Rule-change impact gate

### Q25. What is the denominator of the reroute %?
**Proposed default:** the number of **replayed claims**. Boundary probes are excluded. A claim counts as "rerouted" when its **queue** differs between base and proposed. A different adjuster in the same queue is not a reroute.

**Decision:** accepted default, Tim, 2026-10-06.

### Q26. Is "more than 10%" strict?
**Proposed default:** yes. Exactly 10.0% passes and anything above fails. The same rule (fail only when the count is greater than the threshold) applies to `--max-new-unassigned` (default 0) and `--max-probe-changes` (default 0, see Q30).

**Decision:** accepted default, Tim, 2026-10-06.

### Q27. What counts as "newly unassigned"?
**Proposed default:** assigned under base and unassigned under proposed. Claims unassigned under both rule sets are not new. Claims that go from unassigned to assigned are reported as `newly_assigned` for information only.

**Decision:** accepted default, Tim, 2026-10-06.

### Q28. What are the flag names and exit codes?
**Proposed default:**
- Flags: `--base`, `--proposed`, `--claims FILE` | `--seed N` (default 42) with `--claim-count N` (default 200), `--adjusters FILE` (default: seed roster), `--max-new-unassigned N` (default 0), `--max-reroute-pct P` (default 10), `--max-probe-changes N` (**default 0**, per the Q30 decision), `--json-out PATH`, `--markdown-out PATH` (Markdown also goes to stdout by default).
- Exit codes: 0 pass, 1 policy breach, 2 usage or invalid config (including a negative or non-numeric threshold flag).

**Decision:** accepted default, with `--max-probe-changes` defaulting to 0 as a consequence of Q30. Tim, 2026-10-06.

### Q29. How is a boundary probe claim constructed? The brief says which values to probe, but not what the rest of the claim looks like.
**Proposed default:**
1. Start from a neutral claim: `liability`, `estimated_loss 10000`, no `vehicle_value`, `cat_event false`, `TX`.
2. Apply the **owning rule's other conditions** so the probe reaches that rule:
   - `eq` → that value
   - `in` → the first listed value
   - `gte`/`lte` → the value itself
   - `gt` → value + 1
   - `lt` → value − 1
3. Set the probed field to value−1, value and value+1.

Probes come from every numeric threshold in **either** rule set and are deduplicated by field and value. A probe is compared on **routing only** (queue and matched rule), not assignment, because capacity state would make it noisy.

**Decision:** accepted default, Tim, 2026-10-06.

**Follow-up raised in review:** when the same threshold (field and value) appears in both rule sets but under **different owning rules** (or the owning rule's other conditions differ), whose conditions build the probe claim?
**Decision:** accepted, Tim, 2026-10-06. Build the probe from the **proposed** rule's conditions. The proposed config is what will ship, so its view of the boundary is the one to test. A threshold that exists only in base still uses the base rule.

### Q30. Do boundary-probe changes fail the gate by default?
**Proposed default (superseded):** no. They would be reported but not fail the gate, and teams could opt in with `--max-probe-changes N`.

**Decision:** **changed**, Tim, 2026-10-06. Any boundary-probe routing change now **fails the gate by default**: `--max-probe-changes` defaults to 0, and a breach is reported as policy `max_probe_changes` alongside `max_new_unassigned` and `max_reroute_pct`.

What this means in the scenarios:
- The demo's $50,000 gte→gt off-by-one is a policy breach on its own (exit 1). Changing only that threshold gives 1 probe change, 10.0% rerouted (within policy) and nothing stranded, and the gate still fails.
- The full demo reports all three breaches: 2 newly unassigned, 50.0% rerouted, and 4 probe changes.
- A team can allow a known change explicitly, e.g. `--max-probe-changes 1`.
- Scenarios that test the reroute or newly-unassigned policies in isolation now relax the probe policy by flag. Each one has a comment listing the exact probe changes it allows.

### Q31. Where do the gate's claims and roster come from, and do both runs share the same starting state?
**Proposed default:** both rule sets replay the same claim list in the same order, each from a fresh copy of the same starting roster.
- The seeded generator is deterministic for a given seed.
- The reports contain no timestamps or absolute paths, so two runs are byte-identical.

**Decision:** accepted default, Tim, 2026-10-06.

### Q32. What do the report formats look like?
**Proposed default:**
- JSON top-level keys: `summary` (`replayed_claims`, `seed`, `reroute_pct`, `unassigned_base`, `unassigned_proposed`), `policy_breaches[]` (`policy`, `threshold`, `actual`), `newly_unassigned[]`, `newly_assigned[]`, `queue_changes[]` (changed queues only, sorted by name), `rerouted[]`, `boundary_probes[]`, `boundary_probe_changes[]`.
- Markdown `##` sections, in order: Summary, Policy breaches, Newly unassigned, Queue changes, Rerouted claims, Boundary probe changes.
- Markdown also goes to stdout when `--markdown-out` is not given.

**Decision:** accepted default, Tim, 2026-10-06.

**Follow-up raised in review:** how precise is `reroute_pct`, and does the policy compare the displayed number?
**Decision:** accepted, Tim, 2026-10-06. `summary.reroute_pct` and the breach's `actual` are rounded to **1 decimal** for display (1 of 3 → `33.3`). The `max_reroute_pct` policy compares the **unrounded** value: 33.33…% breaches `--max-reroute-pct 33.3` but passes `33.34`. *Covered by:* `rule_change_gate`, "The reroute policy compares the unrounded percentage…".

### Q33. Does a queue's size in "queue size changes" count unassigned claims routed to it?
**Proposed default:** yes. The size is the number of claims routed to the queue, assigned or not.

**Decision:** accepted default, Tim, 2026-10-06.

## G. Web UI

### Q34. Can claims ops edit rules in the UI?
The problem statement says business users change rules "with clicks", but the Application section only lists "view … the current rules".
**Proposed default:** the rules page is **read-only** in v1. Rules change via a PR to `config/dispatch_rules.json`, which is exactly where the impact gate runs. A click-to-edit UI would need its own gate hook (run the gate before saving) and is a separate phase.

**Decision:** **confirmed**, Tim, 2026-10-06. The rules page is read-only, and rule edits arrive as PRs to `config/dispatch_rules.json`, where the gate runs.

### Q35. Which work-queue filters, what sort order, and is there pagination?
**Proposed default:**
- Filters: queue, status (assigned/unassigned), adjuster and loss state. They combine with AND and are kept in the URL, so they survive a reload.
- Sort: newest first. There's no pagination in v1.

**Decision:** accepted default, Tim, 2026-10-06.

*Clarified per review (2026-10-06):*
- The "Queue" filter options are **every queue in the active rules, plus `general_intake`, plus any queue that still holds claims** (e.g. one removed from the rules). Configured queues are offered whether or not any claim is in them, so a filter can return an empty result, which shows `queue-empty`.
- *Decision (Tim's delegate, 2026-10-06):* the UI filter and the API agree. The list endpoint's `queue` filter (Q38) and the stats endpoint's `by_queue` (Q43) use this same set.
- "Newest first" means most recently created; claims created in the same instant keep reverse creation order.

### Q36. Is the human-readable reason's wording specified?
**Proposed default:** no. Scenarios assert only that it's present and non-empty, so the wording can change freely.

**Decision:** accepted default, Tim, 2026-10-06.

## H. Concurrency

### Q37. Concurrency: dispatch is read-then-write and can race (from the brief's k6 section).
These Cucumber scenarios are single-threaded and can't prove the capacity guarantee.
**Proposed default (superseded):** the developer enforces capacity atomically, with a conditional `UPDATE … WHERE open_claims < capacity` or a row lock. The k6 phase's capacity audit is the acceptance test for this.

**Decision:** accepted default, Tim, 2026-10-06, then narrowed by a **technical decision of the engineering lead (2026-10-06, raised in code review): the atomic conditional UPDATE with retry is the required mechanism.**

- **Claim a slot** with `UPDATE adjusters SET open_claims = open_claims + 1 WHERE id = ? AND open_claims < capacity`, and check the affected-row count.
- **No row lock.** The row-lock option is removed: SQLite has no `SELECT … FOR UPDATE`, and Rails' `lock` is a no-op on it, so a lock-based design would look correct and still race.
- **Losing the race:** if the UPDATE affects 0 rows, another request took the slot. Dispatch **re-selects among the remaining qualified adjusters**, in the same lowest-utilization, then adjuster-ID order, excluding the one that just filled, and retries.
- **Transaction boundaries** (per review, 2026-10-06):
  - **Selection** of the candidate is a plain read with **no write transaction open**. The test seam (`STEP_GLOSSARY.md` §9) runs at this point.
  - **The write:** after selection, the conditional UPDATE plus the claim/assignment write run together in their **own short transaction**. If the UPDATE affects 0 rows, that transaction is rolled back.
  - **A re-select** after a lost race starts afresh: a new read, then a **new** transaction.
  - **Why:** holding a write transaction across selection breaks under SQLite. With `IMMEDIATE` transactions, a thread waiting at the barrier while holding the write lock blocks every other thread, giving `BusyException` or a barrier timeout. With `DEFERRED` transactions and WAL, upgrading a read to a write fails with `SQLITE_BUSY_SNAPSHOT`, which the busy timeout does not retry.
- **Unassigned:** `qualified_adjusters_at_capacity` is returned **only when every qualified adjuster is full**. A lost race on one adjuster never strands a claim while another qualified adjuster has room.
- **Release on re-dispatch** uses `open_claims = open_claims - 1 WHERE id = ? AND open_claims > 0`.
- SQLite runs with a busy timeout, so concurrent writers wait for the write lock instead of erroring (`STEP_GLOSSARY.md` §9).

*Covered by:*
- The `@concurrency` scenarios in `load_and_capacity.feature`: 20 simultaneous dispatches against 2 slots, and 10 against a 6-slot pool that must fill exactly. The latter depends on the re-select rule.
- A test-only seam after candidate selection makes every thread race for the same snapshot, so the scenarios are deterministic.
- The audit after every k6 profile (Q40, Q49).

---

# Scope additions (Tim, 2026-10-06)

## I. First batch

### Q38. List endpoint
`GET /api/claims` with:
- **Filters:** `queue`, `status`, `adjuster_id`, `loss_state`, combined with AND.
- **Pagination:** `page` (from 1) and `per_page` (default 25, max 100).
- **Response:** `200 {page, per_page, total, total_pages, data: [...]}`, newest first.

API checks: status code, `Content-Type: application/json` (on every endpoint), filter correctness, field shapes and types, and pagination math:
- `total_pages == ceil(total/per_page)`
- the last page holds the remainder
- a page past the end is 200 with empty `data`

Invalid filters and paging values return 422.

*Analyst detail:*
- `total_pages` is 0 when `total` is 0.
- Each entry has the same `{claim, dispatch}` shape as `GET /api/claims/:claim_number` and conforms to `contracts/claim_resource.schema.json`.
- **`contracts/claim_resource.schema.json`:**
  - A top-level object with exactly two required properties, `claim` and `dispatch`, and `additionalProperties: false`.
  - Both properties reuse the definitions from the webhook contract by `$ref`, e.g. `claim_dispatched.schema.json#/$defs/claim` and `#/$defs/dispatch`. To allow that, Q23's schema defines `claim` and `dispatch` under `$defs`, each with `additionalProperties: false`, so the two contracts can't drift.
  - There is no `event`, `event_id`, `occurred_at` or `sequence`; those belong to the webhook envelope.
  - *Covered by:* the "claim resource contract" outlines in `api_claims_list.feature`. Their `a valid claim resource payload` step first asserts the sample conforms.
- `queue` must be a configured queue, `general_intake`, or a queue that still holds claims (Q35, Q43). *Covered by:* "A queue removed from the rules can still be filtered while it holds claims" returns 200 with a total of 3. `adjuster_id` must be a known adjuster; `status` must be `assigned` or `unassigned`; `loss_state` follows the Q1 rules. Unknown query parameters are `unknown_field`, and all invalid parameters are reported together.
- A valid filter that matches nothing returns 200 with an empty page.

*Covered by:* `api_claims_list.feature`.

**Decision:** added, Tim, 2026-10-06.

### Q39. API authentication (replaces Q21)
- Every API request needs `Authorization: Bearer <token>`. Tokens are configured with a role, `ops` or `adjuster`.
- A missing or unknown token gets **401** with `WWW-Authenticate: Bearer` and an errors body.
- An `adjuster` token can read (GETs, including list and stats) but gets **403** on create and re-dispatch.
- The web UI stays unauthenticated in v1.

*Analyst detail:*
- Auth is checked first, so an unauthenticated request for an unknown claim is 401, not 404.
- The scheme is `Bearer` and the token is matched exactly (case-sensitive).
- Error codes are `unauthorized` and `forbidden`.
- A rejected request has no side effects: no claim is created and no webhook is sent.

*Covered by:* `api_dispatch.feature` (`@auth`), `api_claims_list.feature`, `api_claims_stats.feature`.

**Decision:** added, Tim, 2026-10-06.

### Q40. Load test criteria
The k6 script has smoke, load (ramp, hold, ramp down) and stress profiles. A run fails **only** through thresholds:
- `http_req_failed rate<0.01`
- `http_req_duration p(95)<300`
- `checks rate>0.99`

Checks cover status and body shape. Every iteration has think time. A comment in the script explains why it uses p95 rather than the average. After the load run, the capacity audit fails if any adjuster has `open_claims > capacity`.

*Analyst detail:* the shapes, think-time range and reviewer checklist are in `docs/specs/LOAD_TEST_CRITERIA.md`. The executable parts (audit, concurrency race, k6 runs) are in `features/load_and_capacity.feature`. The audit covers inactive adjusters too. Q49 extends this decision.

**Decision:** added, Tim, 2026-10-06.

### Q41. Locator strategy
- Form fields are located by their visible **label**, and buttons and links by their **accessible name**.
- `data-testid` is only for things with no user-facing label: page containers, table rows and cells, badges, counts and displayed values.

*Analyst detail:*
- The full priority order is in `STEP_GLOSSARY.md`, "Locator priority".
- Field errors are asserted through `aria-invalid` and `aria-describedby` on the labelled field, not through a testid.
- The read-only rules page is asserted as "contains no form controls", not by the absence of a named button.

**Decision:** added, Tim, 2026-10-06.

### Q42. Page objects and no sleeps
- Step definitions go through Capybara page objects in `features/support/pages/`, one per page.
- Only Capybara's waiting finders and matchers are allowed.
- `sleep` is banned.

*Analyst detail:* time-dependent behaviour (rate limits, event ordering) uses an injectable clock instead (`STEP_GLOSSARY.md` §2a). The ban is enforced by review plus a grep for `sleep` under `features/`. k6 think time is out of its scope.

**Decision:** added, Tim, 2026-10-06.

## J. Second batch

### Q43. Stats endpoint
`GET /api/claims/stats` (any valid token) returns the count and total `estimated_loss` per queue and per status, plus a grand total. It's computed with one GROUP BY query.

*Analyst detail (decided here):*
- **A queue with no claims appears with zeros.** `by_queue` always lists every configured queue plus `general_intake`, plus any other queue that still holds claims, so a dashboard's shape is stable. `by_status` always lists both `assigned` and `unassigned`. An empty database returns the full shape, all zeros.
- Shape: `{by_queue: [{queue, count, total_estimated_loss}], by_status: [{status, count, total_estimated_loss}], total: {count, total_estimated_loss}}`. `by_queue` is sorted by queue name; `by_status` is `assigned` then `unassigned`. Sums are integers.
- The route is declared before `/api/claims/:claim_number`, so `stats` is never treated as a claim number.
- "One query" is asserted as exactly one `SELECT` on `claims` during the request.

*Covered by:* `api_claims_stats.feature`. This includes the check that the totals equal the sums over every page of the list endpoint, and a scenario where `luxury_auto` (which holds claims) and `cat_large_loss` (empty) are removed from the rules: `luxury_auto` stays listed with its claims and `cat_large_loss` disappears.

**Decision:** added, Tim, 2026-10-06.

### Q44. No lying status codes
- An error is never returned as 2xx.
- Every 4xx body has an `errors` array.
- A 2xx body never has an `errors` key.

*Analyst detail:* the array must be non-empty, and every entry needs a string `code`. Unassigned dispatches are successes (201) and must not carry `errors`. The step `the response status and body agree` is applied to every error scenario and to representative successes, with one explicit outline across all endpoints.

**Decision:** added, Tim, 2026-10-06.

### Q45. Webhook signature
Every delivery has `X-Dispatch-Signature: sha256=<hex HMAC-SHA256 of the raw body with a shared secret>`.

*Analyst detail:*
- The HMAC covers the exact bytes sent, so consumers must verify before parsing; re-serialised JSON fails verification.
- Comparison is constant-time.
- The secret is configured per environment.

*Covered by:* valid, tampered, wrong-secret and re-serialised cases.

**Decision:** added, Tim, 2026-10-06.

### Q46. Event IDs are unique and stable, for de-duplication
`event_id` is unique per event and stable, so consumers can de-duplicate.

*Analyst detail:*
- The ID is assigned when the event is created, and any redelivery of that event reuses it.
- A re-dispatch is a **new** event with a new ID.

*Covered by:* a de-duplicating test consumer processes a twice-received delivery once, but processes both the dispatch and re-dispatch events.

**Decision:** added, Tim, 2026-10-06.

### Q47. Webhook ordering
A dispatch followed by a re-dispatch gives two events with increasing `occurred_at` and an increasing per-claim `sequence`.

*Analyst detail:*
- `sequence` starts at 1 for each claim and increments by 1; it is the authoritative order.
- `occurred_at` is UTC with millisecond precision and is non-decreasing (strictly increasing in the test, which advances the controllable clock).

Q23 has been updated to match.

**Decision:** added, Tim, 2026-10-06.

### Q48. Rate limiting
- Per token: N requests per window, configurable, with a low value in tests.
- Request N+1 gets **429** with a `Retry-After` header and an errors body (`rate_limited`).
- A second token is unaffected in the same window.
- After the window resets, requests succeed again.
- Tests use a controllable clock, not sleeps.

*Analyst detail:*
- The window is fixed and starts at the token's first request in it.
- *Covered by:* scenarios showing that 4xx responses count toward the limit (three 422s, then a 429), and that auth runs before the limiter: an unknown token gets 401 on every request, never 429, and uses up no real token's allowance.
- `Retry-After` is the whole seconds until the window resets.
- Every authenticated API endpoint counts, including requests that end in 4xx. A 429 itself doesn't extend the window.
- Unauthenticated requests are rejected with 401 before rate limiting.
- A rate-limited create has no side effects.
- The default in test and load environments is high enough never to trigger.

**Decision:** added, Tim, 2026-10-06.

### Q49. More load profiles
- **storm:** a baseline, then a sudden burst of CAT-event property claims in TX/FL/LA, then recovery. Every claim must get a terminal result and the thresholds must hold.
- **soak:** moderate load for a long, configurable duration, with a short CI default.
- **stress:** steps VUs up until thresholds break and reports the breaking point. It is informational and must not fail CI.
- The capacity audit runs after every profile.

*Analyst detail:*
- Shapes and defaults are in `LOAD_TEST_CRITERIA.md`. Soak defaults to `2m` in CI.
- Stress uses `abortOnFail` through `bin/stress_run`.
  - After any **completed** run it always exits 0, whatever the thresholds did, and writes `breaking_point_vus` and `first_failed_threshold`.
  - If k6 **can't start** (missing binary, unreachable app, script error), there's no stress result: the runner exits **2** as an error, so a broken job isn't mistaken for an informational pass.
  - The capacity audit is a separate step after it and still fails the nightly job, because over-assignment is never acceptable.
- Cucumber tags: **`@k6_pr`** is the smoke profile, which gates every PR. **`@k6_nightly`** covers load, storm, soak, stress and the latency-breach check (`LOAD_TEST_CRITERIA.md`, `STEP_GLOSSARY.md` §9).
- This changes the Q40 stress profile from gating to informational.

**Decision:** added, Tim, 2026-10-06.

### Q50. Money input
- The UI's "Estimated loss" and "Vehicle value" accept formatted input (`$120,000`, `120000`, `120,000.00`) and store whole dollars.
- Non-zero cents (`120,000.50`) are rejected with a visible error.
- The API accepts only JSON integers; a string such as `"$1,200"` gets 422 `invalid_value`.

*Analyst detail:*
- **UI:** a leading `$`, thousands commas and a `.00` suffix are accepted. Letters, negatives, exponent notation and non-zero cents are rejected.
- **API:** Q20 has the authoritative table.
  - **`invalid_value`:** any JSON string in a money field (`"lots"`, `"12000"`, `"$1,200"`), and any other non-number: `true`, `[]` or `{}`.
  - **`not_an_integer`:** a number with a fractional part.
  - **`out_of_range`:** a negative.
  - **`missing`:** `null` in the required `estimated_loss`.
  - **Dropped:** `not_a_number` is no longer used, so a value is never ambiguous between two codes.
  - *Covered by:* the 422 outline in `api_dispatch.feature`, including `true`, `[]`, `{}` and `null` rows.

**Decision:** added, Tim, 2026-10-06.

### Q51. Re-dispatch confirmation
- Clicking "Re-dispatch" shows a JS confirm dialog.
- Accepting re-dispatches the claim; dismissing leaves the assignment and history unchanged.
- The result appears asynchronously, and scenarios rely on Capybara's waiting matchers.

*Analyst detail:*
- These scenarios are tagged `@javascript`.
- The "dismiss" scenario reloads the page before asserting nothing changed, so a stray async request can't race the check.
- The confirm message's wording isn't asserted.

**Decision:** added, Tim, 2026-10-06.

## K. Deferred

### Q52. Adjuster out-of-office windows
Adjusters being unavailable for a date range (holiday, sick leave), which would make them temporarily ineligible.

**Decision:** deferred, Tim, 2026-10-06. Out of scope for now; no scenarios. Until then, `active: false` is the only way to take an adjuster out of rotation.

---

# Phase 2 product decisions (raised by the developer on `phase-2/engine`)

## L. Demo and shipped data

### Q53. What is the canonical demo command?
The brief's demo numbers (2 stranded, 50.0% rerouted, 4 probe changes) come from the 10-claim replay set and the 8-adjuster roster in `rule_change_gate.feature`'s Background. The bare command `bin/rule_diff --base config/dispatch_rules.json --proposed examples/dispatch_rules.proposed.json` instead replays seed 42 × 200 generated claims against the shipped roster. It gives different numbers: exit 1, 1 stranded, 4.0% rerouted, 4 probe changes.

**Decision:** analyst default, delegated by Tim, 2026-10-06. There are two named commands, and the docs say which is which.

1. **The demo** (exact, reproduces the brief and the `@demo` scenario):
   ```
   bin/rule_diff --base config/dispatch_rules.json \
                 --proposed examples/dispatch_rules.proposed.json \
                 --claims examples/replay_claims.json \
                 --adjusters examples/demo_adjusters.json
   ```
   - `examples/demo_adjusters.json` is the 8-adjuster Background roster: today's `config/adjusters.json` content, moved and unchanged.
   - Pinning `--adjusters` keeps the demo independent of the shipped roster (Q54), so enlarging that roster can never change the demo's numbers.
   - Expected: exit 1, with breaches exactly `max_new_unassigned` 0 → 2, `max_reroute_pct` 10 → 50.0 and `max_probe_changes` 0 → 4. Newly unassigned are CLM-2003 and CLM-2004 (`luxury_auto`, `qualified_adjusters_at_capacity`). These are the same values the `@demo` scenario asserts.
2. **The realistic day** is the bare seeded command above. It uses seed 42, 200 claims and the shipped roster `config/adjusters.json`. It must exit 1 with at least one newly stranded claim, but its exact numbers aren't part of the spec. They depend on the seed, the generator and the roster, and the developer records them in `examples/README.md`.

**Docs:** the README and `examples/README.md` lead with command 1, labelled "Demo (the brief's scenario)", followed by command 2, labelled "Realistic day (seeded)". Both show their expected outcome.

**Acceptance checks (developer tests, outside Cucumber):**
- **Demo command:** a CLI test runs command 1 exactly as written, from the repo root, and asserts the exit code, the three breaches with their actual values, and the two newly unassigned claims.
- **Shared data:** a data test asserts that `examples/replay_claims.json` has the same 10 claims as the `rule_change_gate.feature` Background, and that `examples/demo_adjusters.json` has the same 8 adjusters. The fixtures can't drift from the spec.

`features/rule_change_gate.feature` needs no change: its Backgrounds keep their own tables and don't read shipped files.

### Q54. What roster ships in `config/adjusters.json` for seeded runs?
The 8-adjuster, 28-slot Background roster is far too small for a 200-claim day: 177 of 200 seeded claims end up unassigned under **both** rule sets. A seeded run can then hardly detect newly stranded claims.

**Decision:** analyst default, delegated by Tim, 2026-10-06. `config/adjusters.json` becomes a **25-adjuster roster** (24 active), sized from the seed generator's volume mix (`lib/dispatch/scenario_generator.rb`: states weighted TX/FL/CA heaviest, plus CO and WY; 55% auto, 35% property with 30% CAT in TX/FL/LA, 10% liability).

**Hard constraints:**
- **ADJ-001 to ADJ-008** are kept with exactly their current properties, so the IDs and every Background stay valid (the Backgrounds still use their own tables).
- **ADJ-004** (CA, NV, AZ; `luxury_vehicle`; capacity 2) stays the **only active `luxury_vehicle` adjuster licensed outside TX/FL**. New `luxury_vehicle` adjusters are licensed in TX and/or FL only. Luxury overflow in CA/NV/AZ therefore still strands, and luxury claims in NY/NJ/GA/LA/CO/WY have no qualified adjuster.
- **Coverage:** every state the generator emits (TX, FL, CA, NY, LA, AZ, GA, NV, NJ, CO, WY) has at least one active adjuster with `auto` + `large_loss`, and at least one with `property`. TX, FL and LA each have at least one active adjuster with `cat` + `large_loss` and one with `property` + `cat`.

**Adjusters to add** (all `active: true`, `open_claims: 0`):

| id | name | licensed_states | skills | capacity |
|---|---|---|---|---|
| ADJ-009 | Ines Lowry | TX | auto, large_loss | 15 |
| ADJ-010 | Jamal Ortega | TX, LA | auto, large_loss | 15 |
| ADJ-011 | Kira Patel | FL | auto, large_loss | 15 |
| ADJ-012 | Luis Quintero | TX, FL | auto, luxury_vehicle | 8 |
| ADJ-013 | Mara Reyes | TX, LA | property, cat, large_loss | 16 |
| ADJ-014 | Nolan Shaw | FL | property, cat, large_loss | 16 |
| ADJ-015 | Opal Tran | TX, FL, LA | property, cat | 18 |
| ADJ-016 | Priya Usman | CA | auto, large_loss | 16 |
| ADJ-017 | Quinn Vega | CA, NV | auto | 14 |
| ADJ-018 | Rosa Wade | CA, AZ, NV | property | 18 |
| ADJ-019 | Sam Xu | NY, NJ | auto, large_loss | 16 |
| ADJ-020 | Tara Young | NY, NJ | property | 12 |
| ADJ-021 | Uma Zeller | GA, FL | auto, large_loss, property | 12 |
| ADJ-022 | Victor Abbott | AZ, NV | auto, large_loss | 10 |
| ADJ-023 | Wren Baker | CO, WY | auto, large_loss, property | 12 |
| ADJ-024 | Xavi Cole | LA, GA | auto, property | 10 |
| ADJ-025 | Yara Diaz | FL, LA | property, cat | 12 |

**Totals:**
- 25 adjusters, 24 of them active; ADJ-007 stays inactive.
- Active capacity is 258: 23 from ADJ-001–008 plus 235 from the new adjusters.
- Expected assignable demand for a 200-claim day is about 195, so there's roughly 1.3× headroom overall. Every pool (auto, complex, luxury TX/FL, cat_large_loss, coastal, property_standard, CO/WY) has its own headroom.

**What stays unassigned, by design, under base rules (estimated):**
- About 5 luxury claims in states with no qualified luxury adjuster: NY, NJ, GA, LA, CO, WY.
- About 2 CA/NV/AZ luxury claims beyond ADJ-004's 2 slots.

That's well under the 10% budget.

**Why the bare seeded command still catches the demo edit:** at `vehicle_value gte 60000`, CA/NV/AZ autos worth $60k–$99k move to `luxury_auto`, where ADJ-004 is already full. Autos in that range in NY/NJ/GA/LA/CO/WY move to a queue with no qualified adjuster. Both groups were assigned under base, so they become newly stranded; expect several.

**Acceptance checks (developer tests in the plain-Ruby engine suite, no DB):**
1. **Base-rule assignment ≥ 90%:** replay `ScenarioGenerator.new(seed: 42, count: 200).claims`, in order, against `config/dispatch_rules.json` and a fresh copy of `config/adjusters.json`. At least **180 of 200** claims must be assigned. The test prints the actual count and the unassigned claims grouped by reason code on failure.
2. **Roster invariants:**
   - Exactly 25 adjusters and unique IDs.
   - ADJ-001 to ADJ-008 equal the Background table field for field.
   - The set of active `luxury_vehicle` adjusters with any license outside TX/FL is exactly `[ADJ-004]`, with capacity 2.
   - The coverage constraints above hold for every generator state.
   - No adjuster starts with `open_claims > capacity`.
3. **The realistic day still detects the demo edit:** running command 2 (the bare seeded command) exits **1**, `newly_unassigned` has **at least 1** entry, and `policy_breaches` includes `max_new_unassigned`.
4. **The demo is unaffected:** the Q53 demo-command test passes. It pins `examples/demo_adjusters.json`, so it doesn't depend on this roster.

If check 1 fails, raise capacity on the pool the failure report names; don't change the constraints. If check 3 fails, that's a product finding, so escalate it rather than tuning the roster until it passes.

The feature Backgrounds keep their own tables and must not read `config/adjusters.json`.

---

### Q55. Gaps found by QA in phase 2 (G1–G5)

**Decision: orchestrator default, delegated by Tim, 2026-10-06.**

- **G1, fractional thresholds.** Probes are always whole dollars, because claims are (Q1). For threshold `t`, probe `floor(t)-1`, `floor(t)`, `ceil(t)` and `ceil(t)+1`, deduplicated. For an integer `t` that is the usual `t-1, t, t+1`.
- **Probe identity (fixes D3).** Probes are deduplicated per **(rule, field, value)**, never per value alone. Two thresholds that produce the same probe value each get their own probe, built from their own owning rule's conditions.
- **Non-finite numbers.** Any threshold or claim value that parses to ±Infinity or NaN (e.g. `1e400`) is rejected with `non_numeric_threshold` (rules) or `invalid_value` (claims, roster).
- **Encoding.** Files that aren't valid UTF-8 are rejected as `malformed_json` at path `$`, with exit 2. A leading UTF-8 BOM is stripped and accepted, since Windows PowerShell 5.1 writes one.
- **G2.** A rule must have **at least one** condition (`invalid_value` at `rules[i].conditions`). The catch-all is `general_intake`.
- **G3.** Operator and field types must agree. `gt`/`gte`/`lt`/`lte` are allowed only on numeric fields (`estimated_loss`, `vehicle_value`). `eq`/`in` values must match the field's type (string, number or boolean). A mismatch is `invalid_value`.
- **G5.** `Roster.new` and `Roster#update` apply the same validation as the file loader.
- **Minor.** Markdown on stdout uses LF on every platform. `duplicate_priority` is not reported for a priority that is already `invalid_value`.
- **G6 (added after the phase 2 re-verify).** `eq`/`in` values on enum fields must be valid members: `line_of_business` ∈ {auto, property, liability}, and `loss_state` must be an uppercase 2-letter USPS code (the same check as for claims). Otherwise the result is `invalid_value` at `.value`. Without this, a rule like `loss_state eq "tx"` silently never matches.
- **Root README (Q53).** It's written in the final docs phase. Until then, `examples/README.md` carries the two commands.

---

### Q56. Findings from the phase 2 code review

**Decision: orchestrator, delegated by Tim, 2026-10-06.**

- **M1, probe retention (supersedes part of the Q29 follow-up).** A base threshold is probed, built from its base owning rule, whenever **that rule** no longer has the same (field, op, value) condition in the proposed rules. This includes when the rule was deleted. Before, the probe was dropped if *any* proposed rule had that (field, value), which hid a deleted rule when another rule kept the same number. Proposed thresholds are always probed, as before.
- **Report item fields (Q32 addendum).** The extra JSON item fields are part of the contract:
  - `newly_unassigned`: `base_queue`, `base_adjuster`
  - `newly_assigned`: `adjuster`, `base_queue`, `base_reason_code`
  - `rerouted`: `base_matched_rule`, `proposed_matched_rule`
  - `queue_changes`: `delta`
  - `boundary_probes`: `threshold`, `threshold_rule`, `threshold_source`, `changed`

  So are the Markdown PASS/FAIL headline, the "Newly assigned (informational)" subsection, and the one-line stdout summary when `--markdown-out` is given.
- **Breach display.** If a rounded `actual` equals its threshold, show two decimals (e.g. `10.04`), so a breach never displays as "10.0 > 10".
- **Markdown safety.** Table cells escape `|` and collapse newlines.
- **M1 follow-up: probe identity is the probe claim.** After applying the Q56 retention rule, probes are deduplicated by **(field, value, probe claim)**. When two owners build an identical claim, it's one probe, and the proposed-sourced one is kept. Without this, the demo's `gte 50000` → `gt 50000` builds the same claim from the base and proposed rules and counts one boundary change twice. Owners that build *different* claims at the same value still each get a probe (L1, M1).

---

### Q57. Decisions from the phase 3a QA round

**Decision: orchestrator, delegated by Tim, 2026-10-07.**

- **SQLite locking under load (D4).** Use `default_transaction_mode: immediate` in every environment, so `BEGIN` takes the write lock up front and the busy timeout always applies. Retry a write transaction that hits `BusyException` up to 3 times. Under concurrent load, a dispatch waits; it never returns 500 because of lock contention.
- **Webhook deadline (D1, refines Q24).** The 2 s is one **overall wall-clock deadline** per delivery attempt, covering connect, write and read together. A trickling or blackholed endpoint is cut off at 2 s and recorded as `failed`. Delivery runs **off the request thread** in development and production (an in-process queue), and inline in test for determinism, so the API response never waits on a webhook. `pending` is a valid transient state. A transactional outbox with retries is future work, noted in the README.
- **Page cap (D2).** `page` × `per_page` above 1,000,000 is 422 `out_of_range`.
- **API tokens (D3).** A duplicate token, or a token containing whitespace, refuses to boot.
- **Claim numbers (D5).** A claim number with leading or trailing whitespace, or one equal to a reserved route segment (`stats`), is `invalid_value`.
- **Invalid UTF-8 bodies (D6).** These return JSON 400 `malformed_json` in every environment.
- **Boot checks.** The webhook URL must be an absolute `http`/`https` URL. A missing rules or roster file gives the standard "refusing to boot" message.
- **Codes recorded (QA verdict: acceptable).** 415 is `unsupported_media_type`; 500 is `internal_error`. A whole-number float such as `12000.0` is an integer. Money above 2^53−1 is `out_of_range`. `not_configured` is the delivery state when no URL is set.
- **Capacity audit command.** Both `bin/capacity_audit` and `bin/rails dispatch:capacity_audit` are supported, and steps use `bin/capacity_audit`.
