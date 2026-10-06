# Product Brief: Dispatch Rules Guard

*Author: Tim Moravec. This is the only human-written spec in the repo. Everything else was built from it by the role agents in `.claude/agents/` (see [AI_WORKFLOW.md](AI_WORKFLOW.md)).*

## Problem

Claims platforms let business users change routing rules with clicks instead of code. That's the selling point, and it's also a quality risk: a rules edit never goes through code review or CI, so it can quietly misroute claims or leave work stranded with no adjuster. We want a small claims dispatch engine, plus the test tooling that catches a bad rules change **before** it reaches adjusters.

## Users

- **Claims ops (business user):** edits routing rules and wants to know what a change will do.
- **Adjuster:** works a queue of assigned claims.
- **Downstream systems:** receive a webhook when a claim is dispatched.
- **Engineering / QA:** needs every rules change gated in CI the same way code is.

## What dispatch must do

1. **Route.** Rules live in a JSON config. Each rule has a priority, conditions on claim fields (e.g. `line_of_business`, `estimated_loss`, `vehicle_value`, `cat_event`, `loss_state`) using operators like `eq`, `in`, `gt`, `gte`, `lt`, `lte`, a target queue and required adjuster skills. Rules are evaluated in priority order and the first match wins. No match falls through to a `general_intake` queue.
2. **Qualify.** An adjuster is eligible only if active, **licensed in the claim's loss state**, and holding every required skill. Licensing is a regulatory guardrail: it must be enforced by the engine itself, and no rules config can turn it off.
3. **Balance.** Among eligible adjusters with open capacity, pick the lowest utilization. Ties break deterministically (by adjuster ID).
4. **Explain.** Every result records the matched rule, a machine-readable reason code, and a human-readable reason. An unassigned claim must say *why*: no qualified adjuster, vs. qualified adjusters all at capacity.
5. **Notify.** Emit a `claim.assigned` / `claim.unassigned` webhook. Its shape is pinned by a JSON Schema contract. Webhook failures must never block routing.

Rules config must be **validated at load**: unknown fields, unknown operators, non-numeric thresholds and duplicate priorities are rejected, so a typo can't silently disable a rule.

## The rule-change impact gate (the headline feature)

A CLI that takes a base and a proposed rules file and reports what the change *does*, not what was edited:

- Replays a seeded, realistic set of claims through both rule sets, filling adjuster capacity in order like a busy day.
- Adds **boundary probes** generated from the configs themselves: every numeric threshold in either rule set is probed at value−1, value and value+1. A new threshold gets covered automatically.
- Reports newly unassigned claims, queue size changes, rerouted claims and boundary-probe changes, in Markdown (for a PR comment) and JSON.
- Exits non-zero when policy thresholds are breached (default: any newly stranded claim, or more than 10% of claims rerouted). Thresholds are flags, because they're policy decisions the team owns.
- Must run in CI **without booting the web app**.

**Demo scenario it must catch:** ops lowers the luxury-vehicle threshold from $100k to $60k and, in the same edit, changes a CAT large-loss `gte 50000` to `gt 50000`. The gate should flag the newly stranded claims (the luxury queue overflows the one adjuster licensed outside TX/FL) and the off-by-one at exactly $50,000.

## Application

- Web UI: file a claim, view the work queue with filters, view a claim and re-dispatch it, view adjusters and the current rules.
- REST API: create/dispatch claims, with proper 4xx handling for bad input.
- Seed data: a roster of adjusters across states and skills, and a generator for realistic demo claims.

## Quality bar

- Acceptance criteria are written as Cucumber scenarios **before** implementation.
- The engine is plain Ruby with no gem dependencies; its unit tests run in well under a second with no database.
- UI tests use `data-testid` hooks, not copy or styling.
- API and webhook contract tests.
- Load test (k6: smoke, steady and spike profiles), followed by a capacity audit that fails if any adjuster was over-assigned, because dispatch is read-then-write and can race.
- Flake triage: merge JUnit results from repeated runs and label each test stable, flaky or broken.
- CI (GitHub Actions): fast engine tests first, the impact gate on PRs (posted as a sticky comment), acceptance, k6 smoke plus the audit, and a nightly flake hunt.

## Stack

Ruby 3.3, Rails, SQLite, Cucumber + Capybara, minitest, Grafana k6, Docker, GitHub Actions. Development machine is Windows; CI is Linux.
