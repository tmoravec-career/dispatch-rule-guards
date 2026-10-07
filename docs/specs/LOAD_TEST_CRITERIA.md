# Load test acceptance criteria (k6)

*Decided by Tim, 2026-10-06; see `OPEN_QUESTIONS.md` Q40 and Q49. The specific numbers (VU counts, durations, think-time range) are analyst defaults within those decisions. Change them here, in one place.*

These criteria cover the k6 script (`load/dispatch.js`) and how CI runs it. Its runtime behaviour is checked by `features/load_and_capacity.feature`:
- `@audit` and `@concurrency` run in the acceptance job.
- **`@k6_pr`** (the smoke profile) runs in the k6 job on every PR.
- **`@k6_nightly`** (load, storm, soak, stress and the latency-breach check) runs in the nightly k6 job.
- Neither k6 tag runs in the default Cucumber profile. The rest of the script's structure (profiles, thresholds, checks, think time, the p95 comment) can't be executed as a Cucumber assertion, so the **code reviewer verifies it against the checklist at the bottom**.

## Why this exists

Dispatch reads the eligible adjusters, then writes an assignment. Two concurrent requests can both see an adjuster's last free slot, so a load test that only measures latency would miss the real failure: an adjuster silently over-assigned. **Every k6 run is followed by the capacity audit.** The audit fails if any adjuster has `open_claims > capacity`.

## Profiles

You choose a profile with `K6_PROFILE=<name>`. Every profile goes through the same iteration function and thresholds; only the VU shape changes.

| Profile | Shape (default) | Purpose | Gates CI? | Cucumber tag |
|---|---|---|---|---|
| `smoke` | 1 VU for 30 s | Proves the script and app work end to end | **Yes**: every PR | `@k6_pr` |
| `load` | ramp 0→20 VUs over 2 m, **hold** 20 VUs for 5 m, **ramp down** to 0 over 1 m | Expected busy-day traffic | Yes: nightly | `@k6_nightly` |
| `storm` | **baseline** of 5 VUs for 2 m of normal claims, then a **burst** up to 60 VUs within 15 s, held for 2 m, sending only CAT-event property claims in TX/FL/LA, then **recovery** at 5 VUs of normal claims for 3 m | A hurricane landfall: sudden CAT spike on the coastal queues | Yes: nightly | `@k6_nightly` |
| `soak` | 10 VUs for `K6_SOAK_DURATION` (default **2m** in CI, `2h` for a manual or weekly soak) | Leaks, connection-pool exhaustion and counter drift over time | Yes (short default): nightly | `@k6_nightly` |
| `stress` | steps VUs 10 → 20 → 40 → 80 → 160 → 320, 1 m per step, until a threshold fails | Finds the breaking point | **No: informational only** | `@k6_nightly` |

## Thresholds: the only way a run fails

Every gating profile uses exactly these thresholds:

```js
thresholds: {
  // Fewer than 1% of requests may fail (non-2xx or network error).
  http_req_failed:   ['rate<0.01'],
  // p95, not the average: see the comment requirement below.
  http_req_duration: ['p(95)<300'],
  // More than 99% of checks (status + body shape) must pass.
  checks:            ['rate>0.99'],
}
```

- The script must **not** call `fail()`, `exec.test.abort()` or `exit`, or decide pass/fail any other way. A failing check feeds the `checks` threshold; it doesn't stop the run.
- k6 exits **99** when a threshold fails. CI treats a non-zero exit from a gating profile as a failure.
- **Required comment:** next to `http_req_duration`, the script must explain why it uses p95 and not the average. The gist:
  - An average hides the tail. One request in 20 could take 2 s while the mean still looks fine.
  - Dispatch's slow cases are exactly the tail: retries after losing the conditional `UPDATE` on the last free slot, SQLite busy-timeout waits, and contention during a CAT burst.
  - p95 is what a busy adjuster or integration actually feels, and it's stable enough to gate on, unlike p99 on a 30-second smoke run.

## Each iteration

1. `POST /api/claims` with `Authorization: Bearer ${__ENV.K6_API_TOKEN}` (an `ops` token) and a unique `claim_number`: run id + VU + iteration. The body comes from a small built-in generator:
   - Normal claims: realistic lines of business and states.
   - `storm` burst: `line_of_business: property`, `cat_event: true`, `loss_state` from TX/FL/LA, and `estimated_loss` spread around the 50,000 CAT threshold.
2. `GET /api/claims/:claim_number` for the claim just created.
3. **Checks** (all count toward the `checks` rate):
   - The create returns status `201` and the get returns `200`.
   - `Content-Type` starts with `application/json`.
   - The body has `dispatch.status` of `assigned` or `unassigned`.
   - `dispatch.reason_code` is one of the three reason codes.
   - `assigned` ⇒ `dispatch.adjuster_id` is a string; `unassigned` ⇒ it is `null` and the reason code is one of the two unassigned codes. (This is the "terminal result" rule.)
   - The GET returns the same `claim_number`.
4. **Think time:** `sleep(randomBetween(1, 3))` seconds at the end of **every** iteration, with no exceptions. (This is k6's virtual-user sleep. The `sleep` ban in `STEP_GLOSSARY.md` applies to Cucumber code, not k6.)

Rate limiting (Q48) is configured high enough in the load environment that the token isn't throttled. A `429` would count as a failed request.

## After every profile: capacity audit

CI runs `bin/capacity_audit` after **every** profile, including `stress`. It exits 1 if any adjuster, active or inactive, has `open_claims > capacity`, and prints the violations as JSON (`adjuster`, `open_claims`, `capacity`). A gating profile's job fails if either k6 or the audit fails.

## Storm: terminal results

After `storm`, every claim created during the run must have a terminal dispatch result: `assigned` with an adjuster, or `unassigned` with `no_qualified_adjuster` / `qualified_adjusters_at_capacity`. Nothing can be missing, null or pending. `features/load_and_capacity.feature` checks this against the database.

## Stress: informational

`bin/stress_run` wraps k6 for the `stress` profile:
- It sets `abortOnFail: true` on the same three thresholds, so k6 stops at the first breach.
- It writes `stress_report.json` with `breaking_point_vus` (the VU level of the step where a threshold first failed, or `null` if the app survived the top step), `first_failed_threshold`, and the p95 and error rate per step.
- It **always exits 0** after a completed run, whatever the thresholds did. The breaking point is a number to watch, not a gate.
- If k6 can't start at all (missing binary, unreachable app, script error), that isn't a stress result. The runner exits **2** as an error, so a broken job is never mistaken for an informational pass.
- The capacity audit is a **separate CI step** after the runner. It **does** fail the nightly job, because over-assignment is never acceptable even past the breaking point. The nightly job is non-blocking for PRs.

## Artifacts

Every run exports `--summary-export=k6-summary-<profile>.json` and the audit output, both uploaded as CI artifacts.

## Reviewer checklist

- [ ] Profiles `smoke`, `load` (ramp/hold/ramp-down), `storm` (baseline/burst/recovery, CAT property claims in TX/FL/LA), `soak` (configurable, short CI default) and `stress` (stepped) exist and are selected by `K6_PROFILE`.
- [ ] The thresholds are exactly `http_req_failed rate<0.01`, `http_req_duration p(95)<300` and `checks rate>0.99` on every gating profile.
- [ ] There's no `fail()`, `abort` or custom exit logic in the script.
- [ ] Checks cover status codes, content type and body shape, including the terminal-result rule.
- [ ] Every iteration ends with think time.
- [ ] The p95-versus-average comment is present and explains the tail.
- [ ] CI runs the capacity audit after every profile. The stress runner itself never fails CI on thresholds, but the audit step after it does fail the nightly job on over-assignment.
- [ ] CI selects `@k6_pr` (smoke) on PRs and `@k6_nightly` (load, storm, soak, stress, latency check) nightly.
- [ ] The token comes from the environment, not from source.
