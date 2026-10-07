@cli
Feature: Rule-change impact gate
  As engineering / QA, and as claims ops proposing a rules edit
  I want a CLI that replays claims through the base and proposed rules and reports what the change DOES
  So that a rules edit that strands claims, mass-reroutes work or shifts a boundary is caught in CI
  before it reaches adjusters

  # Rules edits arrive as PRs to config/dispatch_rules.json; this gate runs on those PRs.
  # (The web UI's rules page is read-only. Decided 2026-10-06, OPEN_QUESTIONS.md Q34.)
  #
  # Conventions (see docs/specs/STEP_GLOSSARY.md):
  #   - The gate is run as a subprocess, exactly as CI runs it, with no web app booted.
  #     Its working directory is the scenario's temp dir, where every "… file" Given step
  #     writes its file, so relative paths like "base.json" resolve there.
  #   - summary.reroute_pct is rounded to 1 decimal for display; the policy compares the
  #     unrounded value (OPEN_QUESTIONS.md Q32).
  #   - "comparing A to B" passes --base A --proposed B plus the most recently defined
  #     claims file (--claims) and adjusters file (--adjusters), and writes both reports
  #     to a temp dir (--json-out, --markdown-out).
  #   - Default policy (decided 2026-10-06, OPEN_QUESTIONS.md Q26/Q30). The gate fails if ANY of:
  #       more than 0 claims are newly unassigned        (--max-new-unassigned, default 0)
  #       more than 10% of replayed claims are rerouted   (--max-reroute-pct,    default 10)
  #       more than 0 boundary probes change routing      (--max-probe-changes,  default 0)
  #     Exit codes: 0 pass, 1 policy breach, 2 usage/config error.
  #   - Each rule set is replayed from the same starting roster; claims are dispatched in file
  #     order and fill adjuster capacity as they go, like a busy day.
  #   - "Rerouted" = the claim's queue differs between base and proposed.
  #     Reroute % = rerouted claims / replayed claims * 100 (boundary probes excluded).
  #   - Scenarios that test one policy in isolation relax the others by flag, with a comment
  #     saying exactly which probe changes the edit causes.

  Background:
    Given an adjusters file "roster.json" with the adjuster roster:
      | id      | name        | active | licensed_states | skills                          | capacity | open_claims |
      | ADJ-001 | Avery Chen  | true   | TX, FL          | auto, luxury_vehicle            | 3        | 0           |
      | ADJ-002 | Blake Diaz  | true   | TX, FL          | auto, luxury_vehicle            | 3        | 0           |
      | ADJ-003 | Casey Ford  | true   | TX, LA          | property, cat, large_loss       | 4        | 0           |
      | ADJ-004 | Devon Gray  | true   | CA, NV, AZ      | luxury_vehicle                  | 2        | 0           |
      | ADJ-005 | Emery Hart  | true   | CA, AZ          | auto, large_loss                | 4        | 0           |
      | ADJ-006 | Finley Ito  | true   | NY, NJ          | auto, property                  | 4        | 0           |
      | ADJ-007 | Gale Jones  | false  | CA, NY          | auto, luxury_vehicle, property  | 5        | 0           |
      | ADJ-008 | Harper Kim  | true   | FL, GA          | property, cat, large_loss       | 3        | 0           |
    And a rules file "base.json" with the dispatch rules:
      | priority | id                | conditions                                          | queue             | required_skills  |
      | 10       | cat_large_loss    | cat_event eq true; estimated_loss gte 50000         | cat_large_loss    | cat, large_loss  |
      | 20       | luxury_auto       | line_of_business eq auto; vehicle_value gte 100000  | luxury_auto       | luxury_vehicle   |
      | 30       | auto_fast_track   | line_of_business eq auto; estimated_loss lt 5000    | auto_fast_track   | auto             |
      | 40       | auto_standard     | line_of_business eq auto; estimated_loss lte 25000  | auto_standard     | auto             |
      | 50       | auto_complex      | line_of_business eq auto                            | auto_complex      | auto, large_loss |
      | 60       | coastal_property  | line_of_business eq property; loss_state in TX,FL,LA | coastal_property | property, cat    |
      | 70       | property_standard | line_of_business eq property                        | property_standard | property         |
    And a claims file "replay.json" with the claims:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-2001     | auto             | 12000          | 65000         | false     | CA         |
      | CLM-2002     | auto             | 15000          | 72000         | false     | CA         |
      | CLM-2003     | auto             | 9000           | 88000         | false     | CA         |
      | CLM-2004     | auto             | 20000          | 120000        | false     | CA         |
      | CLM-2005     | auto             | 14000          | 70000         | false     | TX         |
      | CLM-2006     | property         | 50000          |               | true      | TX         |
      | CLM-2007     | property         | 80000          |               | true      | FL         |
      | CLM-2008     | auto             | 3000           | 22000         | false     | NY         |
      | CLM-2009     | property         | 10000          |               | false     | NY         |
      | CLM-2010     | auto             | 8000           | 30000         | false     | AZ         |

  # ---------------------------------------------------------------------------
  # The demo scenario from the brief
  # ---------------------------------------------------------------------------

  @demo
  Scenario: Lowering the luxury threshold and changing gte to gt is caught
    # Base:     every claim is assigned. CA/NV/AZ luxury work has one adjuster (ADJ-004, capacity 2).
    # Proposed: four CA claims now hit luxury_auto; ADJ-004 fills after two and the rest strand.
    #           A CAT claim of exactly $50,000 no longer reaches cat_large_loss.
    #           Four boundary probes change routing: estimated_loss 50000 and
    #           vehicle_value 60000, 60001 and 99999. All three policies are breached.
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | luxury_auto    | vehicle_value gte 60000 |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the gate exits with status 1
    And the gate reports these policy breaches:
      | policy             | threshold | actual |
      | max_new_unassigned | 0         | 2      |
      | max_reroute_pct    | 10        | 50.0   |
      | max_probe_changes  | 0         | 4      |
    And the report lists these newly unassigned claims:
      | claim_number | queue       | reason_code                     |
      | CLM-2003     | luxury_auto | qualified_adjusters_at_capacity |
      | CLM-2004     | luxury_auto | qualified_adjusters_at_capacity |
    And the report lists these queue changes:
      | queue            | base | proposed |
      | auto_standard    | 5    | 1        |
      | cat_large_loss   | 2    | 1        |
      | coastal_property | 0    | 1        |
      | luxury_auto      | 1    | 5        |
    And the report lists these rerouted claims:
      | claim_number | base_queue     | proposed_queue   |
      | CLM-2001     | auto_standard  | luxury_auto      |
      | CLM-2002     | auto_standard  | luxury_auto      |
      | CLM-2003     | auto_standard  | luxury_auto      |
      | CLM-2005     | auto_standard  | luxury_auto      |
      | CLM-2006     | cat_large_loss | coastal_property |
    And the JSON report at "summary.replayed_claims" is 10
    And the JSON report at "summary.reroute_pct" is 50.0
    And the report lists these boundary probe changes, among others:
      | field          | value  | base_queue     | proposed_queue |
      | estimated_loss | 50000  | cat_large_loss | general_intake |
      | vehicle_value  | 60000  | auto_standard  | luxury_auto    |
      | vehicle_value  | 99999  | auto_standard  | luxury_auto    |
    And the report lists no boundary probe change for:
      | field          | value  |
      | estimated_loss | 49999  |
      | estimated_loss | 50001  |
      | vehicle_value  | 59999  |
      | vehicle_value  | 100000 |

  @demo
  Scenario: The demo's gte-to-gt off-by-one at $50,000 fails the gate on its own
    # Only the CAT threshold changes. CLM-2006 (exactly $50,000) is rerouted: 1 of 10 = 10.0%,
    # which is not more than 10%, and ADJ-003 still takes it, so nothing is stranded.
    # The single probe change at estimated_loss 50000 is the only failure reason.
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the gate exits with status 1
    And the gate reports these policy breaches:
      | policy            | threshold | actual |
      | max_probe_changes | 0         | 1      |
    And the JSON report at "newly_unassigned" is []
    And the JSON report at "summary.reroute_pct" is 10.0
    And the report lists these boundary probe changes, among others:
      | field          | value | base_queue     | proposed_queue |
      | estimated_loss | 50000 | cat_large_loss | general_intake |
    And the report lists no boundary probe change for:
      | field          | value |
      | estimated_loss | 49999 |
      | estimated_loss | 50001 |

  @demo
  Scenario: The demo's Markdown report is ready to post as a PR comment
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | luxury_auto    | vehicle_value gte 60000 |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the Markdown report has these sections in order:
      | section                |
      | Summary                |
      | Policy breaches        |
      | Newly unassigned       |
      | Queue changes          |
      | Rerouted claims        |
      | Boundary probe changes |
    And the Markdown report mentions "CLM-2003"
    And the Markdown report mentions "CLM-2004"
    And the Markdown report mentions "50000"
    And the Markdown report mentions "max_new_unassigned"
    And the Markdown report mentions "max_reroute_pct"
    And the Markdown report mentions "max_probe_changes"

  # ---------------------------------------------------------------------------
  # Policy thresholds are flags the team owns
  # ---------------------------------------------------------------------------

  Scenario: A change with no effect passes with an empty report
    Given a rules file "proposed.json" copied from "base.json"
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the gate exits with status 0
    And the gate reports no policy breaches
    And the JSON report at "newly_unassigned" is []
    And the JSON report at "rerouted" is []
    And the JSON report at "queue_changes" is []
    And the JSON report at "boundary_probe_changes" is []
    And the JSON report at "summary.reroute_pct" is 0.0

  Scenario: Rerouting exactly 10% of claims is within the default reroute policy
    # CLM-2008 (loss 3000) leaves auto_fast_track: 1 of 10 claims rerouted.
    # The edit also changes 3 boundary probes (estimated_loss 3000, 3001 and 4999), so the
    # probe policy is relaxed to exactly 3 here to isolate the reroute policy.
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule            | condition              |
      | auto_fast_track | estimated_loss lt 3000 |
    When I run the impact gate comparing "base.json" to "proposed.json" with flags "--max-probe-changes 3"
    Then the gate exits with status 0
    And the gate reports no policy breaches
    And the JSON report at "summary.reroute_pct" is 10.0
    And the report lists these rerouted claims:
      | claim_number | base_queue      | proposed_queue |
      | CLM-2008     | auto_fast_track | auto_standard  |

  Scenario: Rerouting more than 10% of claims fails by default, even with nothing stranded
    # CLM-2008 leaves auto_fast_track and CLM-2003 (vehicle 88000) joins luxury_auto: 2 of 10.
    # ADJ-004 can take both CA luxury claims, so nothing is stranded.
    # Probe changes: estimated_loss 3000, 3001, 4999 and vehicle_value 87000, 87001, 99999.
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule            | condition               |
      | auto_fast_track | estimated_loss lt 3000  |
      | luxury_auto     | vehicle_value gte 87000 |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the gate exits with status 1
    And the gate reports these policy breaches:
      | policy            | threshold | actual |
      | max_reroute_pct   | 10        | 20.0   |
      | max_probe_changes | 0         | 6      |
    And the JSON report at "newly_unassigned" is []

  Scenario Outline: Policy thresholds are set by flags
    # The demo edit: 2 newly unassigned, 50.0% rerouted, 4 probe changes.
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | luxury_auto    | vehicle_value gte 60000 |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate comparing "base.json" to "proposed.json" with flags "<flags>"
    Then the gate exits with status <status>

    Examples:
      | flags                                                               | status |
      | --max-new-unassigned 2 --max-reroute-pct 50 --max-probe-changes 4   | 0      |
      | --max-new-unassigned 1 --max-reroute-pct 50 --max-probe-changes 4   | 1      |
      | --max-new-unassigned 2 --max-reroute-pct 49.9 --max-probe-changes 4 | 1      |
      | --max-new-unassigned 2 --max-reroute-pct 50 --max-probe-changes 3   | 1      |
      | --max-new-unassigned 2 --max-reroute-pct 50                         | 1      |
      | --max-new-unassigned 2 --max-probe-changes 4                        | 1      |

  Scenario: A claim that is unassigned under both rule sets is not "newly" unassigned
    Given a claims file "stranded_both.json" with the claims:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-2101     | auto             | 12000          | 130000        | false     | GA         |
      | CLM-2102     | liability        | 40000          |               | false     | WY         |
    And a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule        | condition                |
      | luxury_auto | vehicle_value gte 120000 |
    # The edit changes 3 boundary probes (vehicle_value 100000, 100001 and 119999); the probe
    # policy is relaxed to exactly 3 so that only the newly-unassigned policy is under test.
    When I run the impact gate with arguments "--base base.json --proposed proposed.json --claims stranded_both.json --adjusters roster.json --max-probe-changes 3"
    Then the gate exits with status 0
    And the JSON report at "newly_unassigned" is []
    And the JSON report at "summary.unassigned_base" is 2
    And the JSON report at "summary.unassigned_proposed" is 2

  Scenario: A claim that is unassigned under base and assigned under proposed is reported as newly assigned
    # Base: three CA luxury claims, and ADJ-004 (capacity 2) strands the third.
    # Proposed: raising the luxury threshold to 110000 moves CLM-2201 to auto_standard (ADJ-005),
    # which frees an ADJ-004 slot for CLM-2203. 1 of 3 is rerouted (33.3%).
    # Probe changes: vehicle_value 100000, 100001 and 109999.
    Given a claims file "luxury_overflow.json" with the claims:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-2201     | auto             | 12000          | 105000        | false     | CA         |
      | CLM-2202     | auto             | 15000          | 130000        | false     | CA         |
      | CLM-2203     | auto             | 9000           | 140000        | false     | CA         |
    And a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule        | condition                |
      | luxury_auto | vehicle_value gte 110000 |
    When I run the impact gate comparing "base.json" to "proposed.json" with flags "--max-reroute-pct 50 --max-probe-changes 3"
    Then the gate exits with status 0
    And the report lists these newly assigned claims:
      | claim_number | queue       | adjuster |
      | CLM-2203     | luxury_auto | ADJ-004  |
    And the JSON report at "newly_unassigned" is []
    And the report lists these rerouted claims:
      | claim_number | base_queue  | proposed_queue |
      | CLM-2201     | luxury_auto | auto_standard  |
    And the JSON report at "summary.unassigned_base" is 1
    And the JSON report at "summary.unassigned_proposed" is 0
    And the JSON report at "summary.reroute_pct" is 33.3

  Scenario Outline: The reroute policy compares the unrounded percentage, not the displayed one
    # 1 of 3 claims rerouted = 33.333...%, reported as 33.3 but compared unrounded.
    Given a claims file "luxury_overflow.json" with the claims:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-2201     | auto             | 12000          | 105000        | false     | CA         |
      | CLM-2202     | auto             | 15000          | 130000        | false     | CA         |
      | CLM-2203     | auto             | 9000           | 140000        | false     | CA         |
    And a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule        | condition                |
      | luxury_auto | vehicle_value gte 110000 |
    When I run the impact gate comparing "base.json" to "proposed.json" with flags "--max-reroute-pct <threshold> --max-probe-changes 3"
    Then the gate exits with status <status>
    And the JSON report at "summary.reroute_pct" is 33.3

    Examples:
      | threshold | status |
      | 33.4      | 0      |
      | 33.34     | 0      |
      | 33.3      | 1      |

  # ---------------------------------------------------------------------------
  # Boundary probes are generated from the configs themselves, and gate by default
  # ---------------------------------------------------------------------------

  @boundary
  Scenario: Every numeric threshold in the base rules is probed at value-1, value and value+1
    Given a rules file "proposed.json" copied from "base.json"
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the report includes boundary probes for:
      | field          | values               |
      | estimated_loss | 49999, 50000, 50001  |
      | vehicle_value  | 99999, 100000, 100001 |
      | estimated_loss | 4999, 5000, 5001     |
      | estimated_loss | 24999, 25000, 25001  |

  @boundary
  Scenario: A threshold that only exists in the proposed rules is probed automatically
    Given a rules file "proposed.json" copied from "base.json" with the added rule:
      | priority | id                  | conditions                                          | queue               | required_skills      |
      | 55       | high_value_property | line_of_business eq property; estimated_loss gte 75000 | high_value_property | property, large_loss |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the report includes boundary probes for:
      | field          | values              |
      | estimated_loss | 74999, 75000, 75001 |
    And the report lists these boundary probe changes, among others:
      | field          | value | base_queue       | proposed_queue      |
      | estimated_loss | 75000 | coastal_property | high_value_property |
      | estimated_loss | 75001 | coastal_property | high_value_property |
    And the report lists no boundary probe change for:
      | field          | value |
      | estimated_loss | 74999 |

  @boundary
  Scenario: A threshold that only exists in the base rules is still probed after the rule is removed
    Given a rules file "proposed.json" copied from "base.json" without rule "auto_fast_track"
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the report includes boundary probes for:
      | field          | values           |
      | estimated_loss | 4999, 5000, 5001 |
    And the report lists these boundary probe changes, among others:
      | field          | value | base_queue      | proposed_queue |
      | estimated_loss | 4999  | auto_fast_track | auto_standard  |

  @boundary
  Scenario: A probe-only change fails the gate by default, with nothing stranded or rerouted
    # No replayed claim is a non-CAT property claim of $75,000 or more, so 0% is rerouted;
    # only the probes at estimated_loss 75000 and 75001 change routing.
    Given a rules file "proposed.json" copied from "base.json" with the added rule:
      | priority | id                  | conditions                                          | queue               | required_skills      |
      | 55       | high_value_property | line_of_business eq property; estimated_loss gte 75000 | high_value_property | property, large_loss |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the gate exits with status 1
    And the gate reports these policy breaches:
      | policy            | threshold | actual |
      | max_probe_changes | 0         | 2      |
    And the JSON report at "rerouted" is []
    And the JSON report at "newly_unassigned" is []
    And the JSON report at "summary.reroute_pct" is 0.0

  @boundary
  Scenario: The team can allow a probe change with a flag
    # Same single off-by-one as the demo; 10.0% rerouted is within policy, nothing stranded.
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate comparing "base.json" to "proposed.json" with flags "--max-probe-changes 1"
    Then the gate exits with status 0
    And the gate reports no policy breaches
    And the report lists these boundary probe changes, among others:
      | field          | value | base_queue     | proposed_queue |
      | estimated_loss | 50000 | cat_large_loss | general_intake |

  # ---------------------------------------------------------------------------
  # Runs in CI without the web app; deterministic; refuses bad input
  # ---------------------------------------------------------------------------

  Scenario: The gate runs with no database and without booting the web app
    Given the environment has no database configured
    And a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | luxury_auto    | vehicle_value gte 60000 |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate comparing "base.json" to "proposed.json"
    Then the gate exits with status 1
    And the gate did not load the web application
    And the JSON report at "summary.replayed_claims" is 10

  Scenario: The seeded claim set is used when no claims file is given, and is reproducible
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule        | condition               |
      | luxury_auto | vehicle_value gte 60000 |
    When I run the impact gate twice with arguments "--base base.json --proposed proposed.json --seed 42"
    Then both runs exit with the same status
    And both JSON reports are identical
    And the JSON report at "summary.replayed_claims" is 200
    And the JSON report at "summary.seed" is 42

  Scenario: An invalid proposed rules file is refused before anything is replayed
    Given a rules file "broken.json" containing:
      """json
      {"rules": [{"id": "luxury_auto", "priority": 20, "queue": "luxury_auto", "required_skills": ["luxury_vehicle"],
                  "conditions": [{"field": "vehicle_value", "op": "gtee", "value": 60000}]}]}
      """
    When I run the impact gate comparing "base.json" to "broken.json"
    Then the gate exits with status 2
    And the gate's error output mentions "unknown_operator"
    And the gate's error output mentions "broken.json"
    And no report is written

  Scenario: An invalid base rules file is refused too
    Given a rules file "broken_base.json" containing:
      """json
      {"rules": [{"id": "luxury_auto", "priority": 20, "queue": "luxury_auto", "required_skills": ["luxury_vehicle"],
                  "conditions": [{"field": "vehicle_value", "op": "gte", "value": "100k"}]}]}
      """
    When I run the impact gate comparing "broken_base.json" to "base.json"
    Then the gate exits with status 2
    And the gate's error output mentions "non_numeric_threshold"
    And the gate's error output mentions "broken_base.json"
    And no report is written

  Scenario: Without --markdown-out the Markdown report is printed to standard output
    Given a rules file "proposed.json" copied from "base.json" with these condition changes:
      | rule           | condition               |
      | cat_large_loss | estimated_loss gt 50000 |
    When I run the impact gate with exactly the arguments "--base base.json --proposed proposed.json --claims replay.json --adjusters roster.json"
    Then the gate exits with status 1
    And the gate's standard output mentions "## Summary"
    And the gate's standard output mentions "## Boundary probe changes"
    And the gate's standard output mentions "max_probe_changes"

  Scenario Outline: Usage errors exit with status 2
    When I run the impact gate with arguments "<arguments>"
    Then the gate exits with status 2
    And no report is written

    Examples:
      | arguments                                                     |
      | --base base.json                                              |
      | --base base.json --proposed missing.json                      |
      | --base base.json --proposed base.json --max-reroute-pct ten   |
      | --base base.json --proposed base.json --max-probe-changes -1  |
