@engine
Feature: Dispatch routing
  As claims ops
  I want every claim routed by priority-ordered rules to a licensed, skilled adjuster with open capacity
  So that work lands with the right person, and when it can't, the result says exactly why

  # Outcome: claims ops can trust that a claim goes to the first matching rule's queue,
  # that adjusters are only ever assigned claims in states they are licensed in,
  # that load is spread by utilization, and that every unassigned claim names its cause.
  #
  # Conventions (see docs/specs/STEP_GLOSSARY.md):
  #   - Lower priority number = evaluated first.
  #   - "conditions" cells are "<field> <op> <value>" clauses joined by ";" and ANDed.
  #     `in` values are comma-separated. A blank required_skills cell means no skills required.
  #   - In claim tables a blank cell means the field is absent from the claim.
  #   - In result tables a blank matched_rule means "no rule matched" and a blank adjuster means unassigned.
  #   - These scenarios exercise the plain-Ruby engine directly: no database, no web app.

  Background:
    Given the dispatch rules:
      | priority | id                | conditions                                          | queue             | required_skills  |
      | 10       | cat_large_loss    | cat_event eq true; estimated_loss gte 50000         | cat_large_loss    | cat, large_loss  |
      | 20       | luxury_auto       | line_of_business eq auto; vehicle_value gte 100000  | luxury_auto       | luxury_vehicle   |
      | 30       | auto_fast_track   | line_of_business eq auto; estimated_loss lt 5000    | auto_fast_track   | auto             |
      | 40       | auto_standard     | line_of_business eq auto; estimated_loss lte 25000  | auto_standard     | auto             |
      | 50       | auto_complex      | line_of_business eq auto                            | auto_complex      | auto, large_loss |
      | 60       | coastal_property  | line_of_business eq property; loss_state in TX,FL,LA | coastal_property | property, cat    |
      | 70       | property_standard | line_of_business eq property                        | property_standard | property         |
    And the adjuster roster:
      | id      | name        | active | licensed_states | skills                          | capacity | open_claims |
      | ADJ-001 | Avery Chen  | true   | TX, FL          | auto, luxury_vehicle            | 3        | 0           |
      | ADJ-002 | Blake Diaz  | true   | TX, FL          | auto, luxury_vehicle            | 3        | 0           |
      | ADJ-003 | Casey Ford  | true   | TX, LA          | property, cat, large_loss       | 4        | 0           |
      | ADJ-004 | Devon Gray  | true   | CA, NV, AZ      | luxury_vehicle                  | 2        | 0           |
      | ADJ-005 | Emery Hart  | true   | CA, AZ          | auto, large_loss                | 4        | 0           |
      | ADJ-006 | Finley Ito  | true   | NY, NJ          | auto, property                  | 4        | 0           |
      | ADJ-007 | Gale Jones  | false  | CA, NY          | auto, luxury_vehicle, property  | 5        | 0           |
      | ADJ-008 | Harper Kim  | true   | FL, GA          | property, cat, large_loss       | 3        | 0           |

  # ---------------------------------------------------------------------------
  # Routing: priority order and first match wins
  # ---------------------------------------------------------------------------

  Scenario: A claim is routed to the queue of the single rule it matches
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1001     | auto             | 12000          | 120000        | false     | CA         |
    Then the claim is routed to queue "luxury_auto" by rule "luxury_auto"
    And the claim is assigned to adjuster "ADJ-004"

  Scenario: When several rules match, the lowest priority number wins
    # Matches cat_large_loss (10), luxury_auto (20) and auto_complex (50).
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1002     | auto             | 60000          | 150000        | true      | TX         |
    Then the claim is routed to queue "cat_large_loss" by rule "cat_large_loss"
    And the claim is assigned to adjuster "ADJ-003"

  Scenario: Priority, not the order rules appear in the config, decides precedence
    Given the dispatch rules:
      | priority | id             | conditions                                         | queue          | required_skills |
      | 50       | auto_any       | line_of_business eq auto                           | auto_any       | auto            |
      | 20       | luxury_auto    | line_of_business eq auto; vehicle_value gte 100000 | luxury_auto    | luxury_vehicle  |
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1003     | auto             | 9000           | 140000        | false     | TX         |
    Then the claim is routed to queue "luxury_auto" by rule "luxury_auto"

  Scenario: All conditions of a rule must hold (conditions are ANDed)
    # vehicle_value would satisfy luxury_auto, but the line of business does not.
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1004     | property         | 8000           | 150000        | false     | NY         |
    Then the claim is routed to queue "property_standard" by rule "property_standard"
    And the claim is assigned to adjuster "ADJ-006"

  Scenario Outline: The "in" operator matches any listed value
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1005     | property         | 8000           |               | false     | <state>    |
    Then the claim is routed to queue "<queue>" by rule "<rule>"

    Examples:
      | state | queue             | rule              |
      | TX    | coastal_property  | coastal_property  |
      | LA    | coastal_property  | coastal_property  |
      | FL    | coastal_property  | coastal_property  |
      | GA    | property_standard | property_standard |
      | NY    | property_standard | property_standard |

  Scenario: The "eq" operator compares booleans exactly
    # A large loss that is not a CAT event must not hit the CAT rule.
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1006     | property         | 80000          |               | false     | TX         |
    Then the claim is routed to queue "coastal_property" by rule "coastal_property"

  Scenario: A condition on a field the claim does not have does not match, and does not error
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1007     | auto             | 12000          |               | false     | TX         |
    Then the claim is routed to queue "auto_standard" by rule "auto_standard"
    And the claim is assigned to adjuster "ADJ-001"

  # ---------------------------------------------------------------------------
  # Fall-through to general_intake
  # ---------------------------------------------------------------------------

  Scenario: A claim that matches no rule falls through to general_intake
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1010     | liability        | 40000          |               | false     | TX         |
    Then the claim is routed to queue "general_intake" with no matched rule
    And the claim is assigned to adjuster "ADJ-001"
    And the reason code is "assigned"

  Scenario: general_intake requires no skills but still enforces licensing
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1011     | liability        | 40000          |               | false     | WY         |
    Then the claim is routed to queue "general_intake" with no matched rule
    And the claim is unassigned with reason code "no_qualified_adjuster"

  Scenario: An empty rule set sends every claim to general_intake
    Given the dispatch rules:
      | priority | id | conditions | queue | required_skills |
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1012     | auto             | 12000          | 120000        | false     | CA         |
    Then the claim is routed to queue "general_intake" with no matched rule
    And the claim is assigned to adjuster "ADJ-004"

  # ---------------------------------------------------------------------------
  # Licensing guardrail (regulatory, enforced by the engine, not by rules)
  # ---------------------------------------------------------------------------

  @guardrail
  Scenario: A skilled adjuster with capacity is not assigned outside their licensed states
    # ADJ-001 and ADJ-002 hold luxury_vehicle and have room, but are licensed only in TX/FL.
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1020     | auto             | 12000          | 130000        | false     | GA         |
    Then the claim is routed to queue "luxury_auto" by rule "luxury_auto"
    And the claim is unassigned with reason code "no_qualified_adjuster"

  @guardrail
  Scenario: Only adjusters licensed in the loss state are considered, even if less utilized adjusters exist elsewhere
    Given adjuster "ADJ-006" has 3 open claims
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1021     | property         | 8000           |               | false     | NY         |
    Then the claim is routed to queue "property_standard" by rule "property_standard"
    And the claim is assigned to adjuster "ADJ-006"

  @guardrail
  Scenario Outline: A rules config cannot switch licensing off
    When I load a rules config:
      """json
      <config>
      """
    Then the rules config is rejected with error "unknown_field"

    Examples:
      | config                                                                                                                                                   |
      | {"enforce_licensing": false, "rules": []}                                                                                                                |
      | {"rules": [{"id": "r1", "priority": 1, "conditions": [], "queue": "q1", "required_skills": [], "ignore_licensing": true}]}                                |
      | {"rules": [{"id": "r1", "priority": 1, "conditions": [], "queue": "q1", "required_skills": [], "licensed_states": ["TX", "FL", "CA", "NV", "AZ", "GA"]}]} |

  # ---------------------------------------------------------------------------
  # Skills
  # ---------------------------------------------------------------------------

  Scenario: An adjuster must hold every required skill
    # ADJ-003 (TX) has cat and large_loss; ADJ-001/002 (TX) have neither.
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1030     | property         | 75000          |               | true      | TX         |
    Then the claim is routed to queue "cat_large_loss" by rule "cat_large_loss"
    And the claim is assigned to adjuster "ADJ-003"

  Scenario: Holding only some of the required skills is not enough
    # auto_complex needs auto AND large_loss; in TX only ADJ-001/002 have auto, neither has large_loss.
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1031     | auto             | 40000          | 30000         | false     | TX         |
    Then the claim is routed to queue "auto_complex" by rule "auto_complex"
    And the claim is unassigned with reason code "no_qualified_adjuster"

  Scenario: Extra skills beyond those required do not disqualify an adjuster
    # coastal_property needs property + cat; ADJ-008 (FL) also holds large_loss.
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1032     | property         | 8000           |               | false     | FL         |
    Then the claim is routed to queue "coastal_property" by rule "coastal_property"
    And the claim is assigned to adjuster "ADJ-008"

  # ---------------------------------------------------------------------------
  # Active status and capacity
  # ---------------------------------------------------------------------------

  Scenario: Inactive adjusters are never assigned
    # ADJ-007 is licensed in CA, has luxury_vehicle and 5 free slots, but is inactive.
    Given adjuster "ADJ-004" has 2 open claims
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1040     | auto             | 12000          | 125000        | false     | CA         |
    Then the claim is routed to queue "luxury_auto" by rule "luxury_auto"
    And the claim is unassigned with reason code "qualified_adjusters_at_capacity"

  Scenario: When the only otherwise-qualified adjuster is inactive, nobody is qualified
    Given adjuster "ADJ-004" is inactive
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1041     | auto             | 12000          | 125000        | false     | NV         |
    Then the claim is unassigned with reason code "no_qualified_adjuster"

  Scenario: Assignments consume capacity until the qualified pool is full
    When these claims are dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1042     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-1043     | auto             | 9000           | 135000        | false     | NV         |
      | CLM-1044     | auto             | 15000          | 110000        | false     | AZ         |
    Then the dispatch results are:
      | claim_number | queue       | matched_rule | adjuster | reason_code                     |
      | CLM-1042     | luxury_auto | luxury_auto  | ADJ-004  | assigned                        |
      | CLM-1043     | luxury_auto | luxury_auto  | ADJ-004  | assigned                        |
      | CLM-1044     | luxury_auto | luxury_auto  |          | qualified_adjusters_at_capacity |
    And adjuster "ADJ-004" should have 2 open claims

  Scenario: An unassigned claim does not consume anyone's capacity
    Given adjuster "ADJ-004" has 2 open claims
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1045     | auto             | 12000          | 120000        | false     | CA         |
    Then the claim is unassigned with reason code "qualified_adjusters_at_capacity"
    And adjuster "ADJ-004" should have 2 open claims

  # ---------------------------------------------------------------------------
  # Load balancing and deterministic tie-break
  # ---------------------------------------------------------------------------

  Scenario: The eligible adjuster with the lowest utilization wins, not the fewest open claims
    Given the adjuster roster:
      | id      | name         | active | licensed_states | skills | capacity | open_claims |
      | ADJ-101 | Indy Lopez   | true   | TX              | auto   | 10       | 3           |
      | ADJ-102 | Jordan Moss  | true   | TX              | auto   | 2        | 1           |
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1050     | auto             | 12000          | 30000         | false     | TX         |
    Then the claim is assigned to adjuster "ADJ-101"

  Scenario: Equal utilization breaks by adjuster ID, regardless of roster order
    # 2/4 and 1/2 are both exactly 50%.
    Given the adjuster roster:
      | id      | name         | active | licensed_states | skills | capacity | open_claims |
      | ADJ-202 | Kai Nolan    | true   | TX              | auto   | 2        | 1           |
      | ADJ-201 | Lee Ortiz    | true   | TX              | auto   | 4        | 2           |
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1051     | auto             | 12000          | 30000         | false     | TX         |
    Then the claim is assigned to adjuster "ADJ-201"

  Scenario: Utilization is compared exactly, so 1/3 and 2/6 are a tie
    Given the adjuster roster:
      | id      | name         | active | licensed_states | skills | capacity | open_claims |
      | ADJ-302 | Morgan Park  | true   | TX              | auto   | 3        | 1           |
      | ADJ-301 | Noel Quinn   | true   | TX              | auto   | 6        | 2           |
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1052     | auto             | 12000          | 30000         | false     | TX         |
    Then the claim is assigned to adjuster "ADJ-301"

  Scenario: Consecutive claims alternate between equally loaded adjusters
    When these claims are dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1053     | auto             | 12000          | 30000         | false     | TX         |
      | CLM-1054     | auto             | 14000          | 28000         | false     | FL         |
      | CLM-1055     | auto             | 9000           | 22000         | false     | TX         |
      | CLM-1056     | auto             | 11000          | 41000         | false     | TX         |
    Then the dispatch results are:
      | claim_number | queue         | matched_rule  | adjuster | reason_code |
      | CLM-1053     | auto_standard | auto_standard | ADJ-001  | assigned    |
      | CLM-1054     | auto_standard | auto_standard | ADJ-002  | assigned    |
      | CLM-1055     | auto_standard | auto_standard | ADJ-001  | assigned    |
      | CLM-1056     | auto_standard | auto_standard | ADJ-002  | assigned    |

  Scenario: Dispatching the same input twice gives the same result
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1057     | auto             | 12000          | 30000         | false     | TX         |
    And the same claim is dispatched again against a fresh copy of the roster
    Then both dispatch results are identical

  # ---------------------------------------------------------------------------
  # Explainability: matched rule, reason code, human-readable reason
  # ---------------------------------------------------------------------------

  Scenario Outline: Every result records the matched rule, a reason code and a human-readable reason
    Given adjuster "ADJ-004" has <adj_004_open> open claims
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1060     | auto             | 12000          | 120000        | false     | <state>    |
    Then the claim is routed to queue "luxury_auto" by rule "luxury_auto"
    And the reason code is "<reason_code>"
    And the result includes a human-readable reason

    Examples:
      | state | adj_004_open | reason_code                     |
      | CA    | 0            | assigned                        |
      | CA    | 2            | qualified_adjusters_at_capacity |
      | GA    | 0            | no_qualified_adjuster           |

  Scenario: "No qualified adjuster" wins over "at capacity" when nobody is qualified at all
    # ADJ-001 and ADJ-002 are full, but they are not licensed in GA, so they are not "qualified".
    Given adjuster "ADJ-001" has 3 open claims
    And adjuster "ADJ-002" has 3 open claims
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1061     | auto             | 12000          | 120000        | false     | GA         |
    Then the claim is unassigned with reason code "no_qualified_adjuster"

  Scenario Outline: "At capacity" is reported only when every qualified, active adjuster is full
    Given adjuster "ADJ-001" has <adj_001_open> open claims
    And adjuster "ADJ-002" has <adj_002_open> open claims
    When these claims are dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1062     | auto             | 12000          | 120000        | false     | TX         |
    Then the dispatch results are:
      | claim_number | queue       | matched_rule | adjuster   | reason_code   |
      | CLM-1062     | luxury_auto | luxury_auto  | <adjuster> | <reason_code> |

    Examples:
      | adj_001_open | adj_002_open | adjuster | reason_code                     |
      | 3            | 2            | ADJ-002  | assigned                        |
      | 2            | 3            | ADJ-001  | assigned                        |
      | 3            | 3            |          | qualified_adjusters_at_capacity |

  # ---------------------------------------------------------------------------
  # Numeric boundaries: value-1, value, value+1 for every threshold
  # ---------------------------------------------------------------------------

  @boundary
  Scenario Outline: Thresholds behave exactly at value-1, value and value+1
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1070     | <lob>            | <loss>         | <vehicle>     | <cat>     | <state>    |
    Then the claim is routed to queue "<queue>" by rule "<queue>"

    Examples: cat_large_loss: estimated_loss gte 50000 (inclusive)
      | lob      | loss  | vehicle | cat  | state | queue            |
      | property | 49999 |         | true | TX    | coastal_property |
      | property | 50000 |         | true | TX    | cat_large_loss   |
      | property | 50001 |         | true | TX    | cat_large_loss   |

    Examples: luxury_auto: vehicle_value gte 100000 (inclusive)
      | lob  | loss  | vehicle | cat   | state | queue         |
      | auto | 12000 | 99999   | false | CA    | auto_standard |
      | auto | 12000 | 100000  | false | CA    | luxury_auto   |
      | auto | 12000 | 100001  | false | CA    | luxury_auto   |

    Examples: auto_fast_track: estimated_loss lt 5000 (exclusive)
      | lob  | loss | vehicle | cat   | state | queue           |
      | auto | 4999 | 20000   | false | TX    | auto_fast_track |
      | auto | 5000 | 20000   | false | TX    | auto_standard   |
      | auto | 5001 | 20000   | false | TX    | auto_standard   |

    Examples: auto_standard: estimated_loss lte 25000 (inclusive)
      | lob  | loss  | vehicle | cat   | state | queue         |
      | auto | 24999 | 20000   | false | TX    | auto_standard |
      | auto | 25000 | 20000   | false | TX    | auto_standard |
      | auto | 25001 | 20000   | false | TX    | auto_complex  |

  @boundary
  Scenario Outline: Changing gte to gt moves exactly the threshold value, and nothing else
    Given rule "cat_large_loss" has condition "estimated_loss gt 50000"
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1071     | property         | <loss>         |               | true      | TX         |
    Then the claim is routed to queue "<queue>" by rule "<queue>"

    Examples:
      | loss  | queue            |
      | 49999 | coastal_property |
      | 50000 | coastal_property |
      | 50001 | cat_large_loss   |

  @boundary
  Scenario Outline: Changing lt to lte moves exactly the threshold value, and nothing else
    Given rule "auto_fast_track" has condition "estimated_loss lte 5000"
    When a claim is dispatched:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-1072     | auto             | <loss>         | 20000         | false     | TX         |
    Then the claim is routed to queue "<queue>" by rule "<queue>"

    Examples:
      | loss | queue           |
      | 4999 | auto_fast_track |
      | 5000 | auto_fast_track |
      | 5001 | auto_standard   |

  # ---------------------------------------------------------------------------
  # Rules config validation at load
  # ---------------------------------------------------------------------------

  @validation
  Scenario: A well-formed rules config loads
    When I load a rules config:
      """json
      {
        "rules": [
          {
            "id": "luxury_auto",
            "priority": 20,
            "conditions": [
              { "field": "line_of_business", "op": "eq",  "value": "auto" },
              { "field": "vehicle_value",    "op": "gte", "value": 100000 }
            ],
            "queue": "luxury_auto",
            "required_skills": ["luxury_vehicle"]
          },
          {
            "id": "coastal_property",
            "priority": 60,
            "conditions": [
              { "field": "line_of_business", "op": "eq", "value": "property" },
              { "field": "loss_state",       "op": "in", "value": ["TX", "FL", "LA"] }
            ],
            "queue": "coastal_property",
            "required_skills": ["property", "cat"]
          }
        ]
      }
      """
    Then the rules config loads with 2 rules

  @validation
  Scenario Outline: A malformed condition is rejected at load, naming the offending path
    When I load a rules config with a single rule whose conditions are:
      """json
      [<condition>]
      """
    Then the rules config is rejected with error "<error>"
    And the error points at "rules[0].conditions[0]<path>"

    Examples:
      | condition                                                               | error                 | path   |
      | {"field": "vehicle_value", "op": "gtee", "value": 100000}               | unknown_operator      | .op    |
      | {"field": "vehicle_value", "op": "=>", "value": 100000}                 | unknown_operator      | .op    |
      | {"field": "vehicle_valu", "op": "gte", "value": 100000}                 | unknown_field         | .field |
      | {"field": "vehicle_value", "op": "gte", "value": 100000, "incl": true}  | unknown_field         | .incl  |
      | {"field": "vehicle_value", "op": "gte", "value": "100k"}                | non_numeric_threshold | .value |
      | {"field": "vehicle_value", "op": "gte", "value": "100000"}              | non_numeric_threshold | .value |
      | {"field": "estimated_loss", "op": "lt", "value": null}                  | non_numeric_threshold | .value |
      | {"field": "estimated_loss", "op": "gt", "value": true}                  | non_numeric_threshold | .value |
      | {"field": "loss_state", "op": "in", "value": "TX"}                      | invalid_value         | .value |

  @validation
  Scenario: An unknown field on a rule is rejected
    When I load a rules config:
      """json
      {"rules": [{"id": "luxury_auto", "priority": 20, "conditions": [], "queue": "luxury_auto", "required_skils": ["luxury_vehicle"]}]}
      """
    Then the rules config is rejected with error "unknown_field"
    And the error points at "rules[0].required_skils"

  @validation
  Scenario: Duplicate priorities are rejected
    When I load a rules config:
      """json
      {
        "rules": [
          {"id": "luxury_auto",   "priority": 20, "conditions": [], "queue": "luxury_auto",   "required_skills": []},
          {"id": "auto_standard", "priority": 20, "conditions": [], "queue": "auto_standard", "required_skills": []}
        ]
      }
      """
    Then the rules config is rejected with error "duplicate_priority"
    And the error points at "rules[1].priority"

  @validation
  Scenario: Duplicate rule IDs are rejected
    When I load a rules config:
      """json
      {
        "rules": [
          {"id": "luxury_auto", "priority": 20, "conditions": [], "queue": "luxury_auto", "required_skills": []},
          {"id": "luxury_auto", "priority": 30, "conditions": [], "queue": "luxury_auto", "required_skills": []}
        ]
      }
      """
    Then the rules config is rejected with error "duplicate_rule_id"
    And the error points at "rules[1].id"

  @validation
  Scenario: A rule missing a required key is rejected
    When I load a rules config:
      """json
      {"rules": [{"id": "luxury_auto", "priority": 20, "conditions": [], "required_skills": []}]}
      """
    Then the rules config is rejected with error "missing_field"
    And the error points at "rules[0].queue"

  @validation
  Scenario: Every problem in a config is reported, and nothing is partially loaded
    When I load a rules config:
      """json
      {
        "rules": [
          {"id": "ok_rule",  "priority": 10, "conditions": [{"field": "estimated_loss", "op": "gte", "value": 50000}], "queue": "q1", "required_skills": []},
          {"id": "typo_op",  "priority": 20, "conditions": [{"field": "estimated_loss", "op": "gtee", "value": 1}],   "queue": "q2", "required_skills": []},
          {"id": "bad_num",  "priority": 20, "conditions": [{"field": "vehicle_value",  "op": "gte", "value": "60k"}], "queue": "q3", "required_skills": []}
        ]
      }
      """
    Then the rules config is rejected with errors:
      | error                 | path                         |
      | unknown_operator      | rules[1].conditions[0].op    |
      | non_numeric_threshold | rules[2].conditions[0].value |
      | duplicate_priority    | rules[2].priority            |
    And no rules are loaded
