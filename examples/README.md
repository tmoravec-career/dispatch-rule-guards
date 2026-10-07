# Rule-change impact gate: examples

`bin/rule_diff` runs with plain Ruby and no bundle. Run these commands from the repo root.

## Demo (the brief's scenario)

This is the brief's demo edit, `examples/dispatch_rules.proposed.json`. It makes two changes:
- it lowers `luxury_auto` from `vehicle_value gte 100000` to `gte 60000`;
- it changes `cat_large_loss` from `estimated_loss gte 50000` to `gt 50000`.

The gate replays the 10 claims and 8 adjusters from the `rule_change_gate.feature` Background:

```
ruby -Ilib bin/rule_diff --base config/dispatch_rules.json \
                         --proposed examples/dispatch_rules.proposed.json \
                         --claims examples/replay_claims.json \
                         --adjusters examples/demo_adjusters.json
```

Expected result: **exit 1**, with all three policies breached.

| Policy | Threshold | Actual |
|---|---|---|
| `max_new_unassigned` | 0 | 2 |
| `max_reroute_pct` | 10 | 50.0 |
| `max_probe_changes` | 0 | 4 |

- **Newly unassigned:** CLM-2003 and CLM-2004 (`luxury_auto`, `qualified_adjusters_at_capacity`). The luxury queue overflows ADJ-004, the only luxury adjuster licensed outside TX/FL.
- **Probe changes:** `estimated_loss` 50000 (the off-by-one), and `vehicle_value` 60000, 60001 and 99999.

`--claims` and `--adjusters` are pinned, so these numbers don't depend on the shipped roster. `test/dispatch/shipped_data_test.rb` runs this exact command and checks that both example files still match the feature Background.

## Realistic day (seeded)

The same edit, replayed against a generated day. The default is seed 42 with 200 claims, against the shipped 25-adjuster roster in `config/adjusters.json`:

```
ruby -Ilib bin/rule_diff --base config/dispatch_rules.json \
                         --proposed examples/dispatch_rules.proposed.json
```

Expected result: **exit 1**, with two policies breached. Only the exit code and "at least one newly stranded claim" are part of the spec (Q53, Q54). The exact numbers below come from the current generator and roster.

| Policy | Threshold | Actual |
|---|---|---|
| `max_new_unassigned` | 0 | 3 |
| `max_probe_changes` | 0 | 4 |

- **Replayed:** 200 claims.
- **Rerouted:** 8 claims (4.0%), which is within the 10% policy.
- **Unassigned:** 16 under base, 17 under proposed. 184 of 200 claims are assigned under the base rules.
- **Newly unassigned:** SIM-0012, SIM-0057 and SIM-0082. These are NY and CO autos worth $60k–$99k that move to `luxury_auto`, where no adjuster is licensed.
- **Newly assigned (informational):** SIM-0159 and SIM-0166.
- **Probe changes:** the same 4 as the demo.

## Other files

- `dispatch_rules.proposed.json`: the demo edit. Diff it against `config/dispatch_rules.json` to see the two changes.
- `replay_claims.json` and `demo_adjusters.json`: the `rule_change_gate.feature` Background claims and roster.

Run `ruby -Ilib bin/rule_diff --help` for every flag. Exit codes: 0 pass, 1 policy breach, 2 usage error or invalid input.
