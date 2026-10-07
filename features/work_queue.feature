@ui
Feature: Work queue web UI
  As claims ops and as an adjuster
  I want to file claims, see the work queue, inspect and re-dispatch a claim, and view adjusters and rules
  So that I can see where work went and why, and fix stranded claims once capacity frees up

  # Locator strategy (docs/specs/STEP_GLOSSARY.md, "Locator priority"; OPEN_QUESTIONS.md Q41):
  #   - Form fields are found by their visible label ("Estimated loss", "Loss state", ...).
  #   - Buttons and links are found by their accessible name ("File claim", "Re-dispatch", "CLM-3003").
  #   - data-testid is used only for things with no user-facing label: page containers,
  #     table rows and cells, badges, counts and displayed values.
  #   - Assertions compare data values (queue names, adjuster IDs, reason codes), never copy or styling.
  #   "<prefix>" row steps match elements whose data-testid is "<prefix>-<key>", e.g. claim-row-CLM-3001.
  #   The web UI is unauthenticated in v1 (Q39).

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
    And these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-3001     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-3002     | auto             | 9000           | 135000        | false     | CA         |
      | CLM-3003     | auto             | 15000          | 110000        | false     | NV         |
      | CLM-3004     | property         | 8000           |               | false     | NY         |
      | CLM-3005     | liability        | 40000          |               | false     | WY         |
      | CLM-3006     | auto             | 3000           | 18000         | false     | TX         |

  # ---------------------------------------------------------------------------
  # File a claim
  # ---------------------------------------------------------------------------

  Scenario: Filing a claim dispatches it and shows the explained result
    When I visit the "new claim" page
    And I fill in "Claim number" with "CLM-3100"
    And I select "auto" from "Line of business"
    And I fill in "Estimated loss" with "14000"
    And I fill in "Vehicle value" with "70000"
    And I select "TX" from "Loss state"
    And I press "File claim"
    Then I am on the claim page for "CLM-3100"
    And "dispatch-status" shows "assigned"
    And "dispatch-queue" shows "auto_standard"
    And "dispatch-matched-rule" shows "auto_standard"
    And "dispatch-adjuster" shows "ADJ-002"
    And "dispatch-reason-code" shows "assigned"
    And "dispatch-reason" is visible

  Scenario: Filing a CAT claim uses the CAT event checkbox
    When I visit the "new claim" page
    And I fill in "Claim number" with "CLM-3101"
    And I select "property" from "Line of business"
    And I fill in "Estimated loss" with "50000"
    And I check "CAT event"
    And I select "TX" from "Loss state"
    And I press "File claim"
    Then I am on the claim page for "CLM-3101"
    And "dispatch-queue" shows "cat_large_loss"
    And "dispatch-adjuster" shows "ADJ-003"

  Scenario: Filing a claim that cannot be assigned shows why
    When I file a claim through the form with:
      | Claim number     | CLM-3102 |
      | Line of business | auto     |
      | Estimated loss   | 12000    |
      | Vehicle value    | 150000   |
      | Loss state       | AZ       |
    Then I am on the claim page for "CLM-3102"
    And "dispatch-status" shows "unassigned"
    And "dispatch-queue" shows "luxury_auto"
    And "dispatch-reason-code" shows "qualified_adjusters_at_capacity"
    And "dispatch-adjuster" is not visible
    And "dispatch-reason" is visible

  Scenario: A claim that matches no rule shows the general_intake fall-through
    When I visit the claim page for "CLM-3005"
    Then "dispatch-queue" shows "general_intake"
    And "dispatch-matched-rule" is not visible
    And "dispatch-no-matched-rule" is visible
    And "dispatch-reason-code" shows "no_qualified_adjuster"

  Scenario Outline: Invalid claim input is rejected on the form and nothing is dispatched
    When I file a claim through the form with:
      | Claim number     | CLM-3103         |
      | Line of business | auto             |
      | Estimated loss   | <estimated_loss> |
      | Vehicle value    | 30000            |
      | Loss state       | <loss_state>     |
    Then I am on the "new claim" page
    And the "<field>" field is marked invalid
    And claim "CLM-3103" does not exist

    Examples:
      | estimated_loss | loss_state | field          |
      | twelve         | TX         | Estimated loss |
      | -100           | TX         | Estimated loss |
      |                | TX         | Estimated loss |
      | 12000          |            | Loss state     |

  Scenario Outline: The CAT event checkbox and Loss state dropdown drive routing
    When I file a claim through the form with:
      | Claim number     | CLM-3120 |
      | Line of business | property |
      | Estimated loss   | 60000    |
      | CAT event        | <cat>    |
      | Loss state       | <state>  |
    Then I am on the claim page for "CLM-3120"
    And "claim-cat_event" shows exactly "<cat>"
    And "claim-loss_state" shows exactly "<state>"
    And "dispatch-queue" shows exactly "<queue>"

    Examples:
      | cat   | state | queue             |
      | true  | TX    | cat_large_loss    |
      | false | TX    | coastal_property  |
      | true  | NY    | cat_large_loss    |
      | false | NY    | property_standard |

  Scenario Outline: Money fields accept formatted input and store whole dollars
    When I file a claim through the form with:
      | Claim number     | CLM-3130        |
      | Line of business | auto            |
      | Estimated loss   | <loss_input>    |
      | Vehicle value    | <vehicle_input> |
      | Loss state       | TX              |
    Then I am on the claim page for "CLM-3130"
    And "claim-estimated_loss" shows exactly "12000"
    And "claim-vehicle_value" shows exactly "120000"
    And "dispatch-queue" shows exactly "luxury_auto"

    Examples:
      | loss_input | vehicle_input |
      | 12000      | 120000        |
      | $12,000    | $120,000      |
      | 12,000.00  | 120,000.00    |
      | $12,000.00 | $120,000.00   |
      | 12000.00   | 120000        |

  Scenario Outline: Money input with cents or junk is rejected with a visible error
    When I file a claim through the form with:
      | Claim number     | CLM-3131        |
      | Line of business | auto            |
      | Estimated loss   | <loss_input>    |
      | Vehicle value    | <vehicle_input> |
      | Loss state       | TX              |
    Then I am on the "new claim" page
    And the "<field>" field is marked invalid
    And claim "CLM-3131" does not exist

    Examples:
      | loss_input | vehicle_input | field          |
      | 12,000.50  | 120000        | Estimated loss |
      | 12000      | 120,000.50    | Vehicle value  |
      | $12,000.5  | 120000        | Estimated loss |
      | 12O00      | 120000        | Estimated loss |
      | -$500      | 120000        | Estimated loss |
      | 12000      | 1.2e5         | Vehicle value  |

  Scenario: A duplicate claim number is rejected on the form
    When I file a claim through the form with:
      | Claim number     | CLM-3001 |
      | Line of business | auto     |
      | Estimated loss   | 12000    |
      | Loss state       | TX       |
    Then I am on the "new claim" page
    And the "Claim number" field is marked invalid

  # ---------------------------------------------------------------------------
  # Work queue with filters
  # ---------------------------------------------------------------------------

  Scenario: The work queue lists every dispatched claim with its outcome
    When I visit the "work queue" page
    Then the "claim-row" rows show:
      | key      | row-queue         | row-status | row-adjuster | row-reason-code                 |
      | CLM-3001 | luxury_auto       | assigned   | ADJ-004      | assigned                        |
      | CLM-3002 | luxury_auto       | assigned   | ADJ-004      | assigned                        |
      | CLM-3003 | luxury_auto       | unassigned |              | qualified_adjusters_at_capacity |
      | CLM-3004 | property_standard | assigned   | ADJ-006      | assigned                        |
      | CLM-3005 | general_intake    | unassigned |              | no_qualified_adjuster           |
      | CLM-3006 | auto_fast_track   | assigned   | ADJ-001      | assigned                        |
    And "queue-count" shows "6"

  Scenario: The work queue is sorted newest first
    # "Newest" = most recently created; claims created in the same instant are listed in
    # reverse creation order (later-inserted first), so the Background's claims read 3006..3001.
    When I file a claim through the form with:
      | Claim number     | CLM-3105 |
      | Line of business | auto     |
      | Estimated loss   | 11000    |
      | Vehicle value    | 26000    |
      | Loss state       | FL       |
    And I visit the "work queue" page
    Then the "claim-row" rows appear in this order:
      | key      |
      | CLM-3105 |
      | CLM-3006 |
      | CLM-3005 |
      | CLM-3004 |
      | CLM-3003 |
      | CLM-3002 |
      | CLM-3001 |

  Scenario Outline: Filtering the work queue
    When I visit the "work queue" page
    And I select "<value>" from "<filter>"
    And I press "Apply filters"
    Then the "claim-row" rows are exactly:
      | key        |
      | <claim_1>  |
      | <claim_2>  |
    And "queue-count" shows "2"

    Examples:
      | filter     | value      | claim_1  | claim_2  |
      | Status     | unassigned | CLM-3003 | CLM-3005 |
      | Adjuster   | ADJ-004    | CLM-3001 | CLM-3002 |
      | Loss state | CA         | CLM-3001 | CLM-3002 |

  Scenario: Filtering by queue
    When I visit the "work queue" page
    And I select "luxury_auto" from "Queue"
    And I press "Apply filters"
    Then the "claim-row" rows are exactly:
      | key      |
      | CLM-3001 |
      | CLM-3002 |
      | CLM-3003 |

  Scenario: Filters combine, and clearing them shows everything again
    When I visit the "work queue" page
    And I select "luxury_auto" from "Queue"
    And I select "unassigned" from "Status"
    And I press "Apply filters"
    Then the "claim-row" rows are exactly:
      | key      |
      | CLM-3003 |
    When I press "Clear filters"
    Then "queue-count" shows "6"

  Scenario: A filter with no matches shows the empty state
    # cat_large_loss has no claims, but it is still offered because it is a configured queue.
    When I visit the "work queue" page
    And I select "cat_large_loss" from "Queue"
    And I press "Apply filters"
    Then the "claim-row" rows are exactly:
      | key |
    And "queue-empty" is visible

  Scenario: Filters survive a page reload
    When I visit the "work queue" page
    And I select "unassigned" from "Status"
    And I press "Apply filters"
    And I reload the page
    Then the "claim-row" rows are exactly:
      | key      |
      | CLM-3003 |
      | CLM-3005 |

  # ---------------------------------------------------------------------------
  # Claim detail and re-dispatch
  # ---------------------------------------------------------------------------

  Scenario: Opening a claim from the work queue shows its claim fields and dispatch explanation
    When I visit the "work queue" page
    And I follow "CLM-3003"
    Then I am on the claim page for "CLM-3003"
    And "claim-loss_state" shows "NV"
    And "claim-vehicle_value" shows "110000"
    And "dispatch-status" shows "unassigned"
    And "dispatch-matched-rule" shows "luxury_auto"
    And "dispatch-reason-code" shows "qualified_adjusters_at_capacity"
    And "dispatch-reason" is visible

  # Re-dispatch asks for confirmation in a JS confirm dialog, and the result is rendered
  # asynchronously, so these scenarios run in a JS-capable driver (@javascript) and every
  # assertion after the click relies on Capybara's waiting matchers, never on sleep (Q51).

  @javascript
  Scenario: Re-dispatching a stranded claim after capacity frees up assigns it
    Given adjuster "ADJ-004" has 1 open claim
    When I visit the claim page for "CLM-3003"
    And I press "Re-dispatch" and accept the confirmation
    Then "dispatch-status" shows "assigned"
    And "dispatch-adjuster" shows "ADJ-004"
    And "dispatch-reason-code" shows "assigned"
    And I see 2 "dispatch-history-entry" elements
    And I am on the claim page for "CLM-3003"

  @javascript
  Scenario: Re-dispatching while still at capacity keeps the claim unassigned with the same reason
    When I visit the claim page for "CLM-3003"
    And I press "Re-dispatch" and accept the confirmation
    Then I see 2 "dispatch-history-entry" elements
    And "dispatch-status" shows "unassigned"
    And "dispatch-reason-code" shows "qualified_adjusters_at_capacity"

  @javascript
  Scenario: Dismissing the confirmation leaves the assignment and history unchanged
    When I visit the claim page for "CLM-3006"
    And I press "Re-dispatch" and dismiss the confirmation
    And I reload the page
    Then "dispatch-adjuster" shows "ADJ-001"
    And I see 1 "dispatch-history-entry" elements
    When I visit the "adjusters" page
    Then the "adjuster-row" rows show:
      | key     | adjuster-load |
      | ADJ-001 | 1/3           |

  @javascript
  Scenario: Re-dispatching an assigned claim does not double-count the adjuster's load
    When I visit the claim page for "CLM-3006"
    And I press "Re-dispatch" and accept the confirmation
    Then I see 2 "dispatch-history-entry" elements
    And "dispatch-adjuster" shows "ADJ-001"
    When I visit the "adjusters" page
    Then the "adjuster-row" rows show:
      | key     | adjuster-load |
      | ADJ-001 | 1/3           |

  # ---------------------------------------------------------------------------
  # Adjusters page
  # ---------------------------------------------------------------------------

  Scenario: The adjusters page shows licensing, skills, load and status for everyone
    When I visit the "adjusters" page
    Then the "adjuster-row" rows show:
      | key     | adjuster-states | adjuster-skills                | adjuster-load | adjuster-status |
      | ADJ-001 | FL, TX          | auto, luxury_vehicle           | 1/3           | active          |
      | ADJ-002 | FL, TX          | auto, luxury_vehicle           | 0/3           | active          |
      | ADJ-003 | LA, TX          | cat, large_loss, property      | 0/4           | active          |
      | ADJ-004 | AZ, CA, NV      | luxury_vehicle                 | 2/2           | active          |
      | ADJ-005 | AZ, CA          | auto, large_loss               | 0/4           | active          |
      | ADJ-006 | NJ, NY          | auto, property                 | 1/4           | active          |
      | ADJ-007 | CA, NY          | auto, luxury_vehicle, property | 0/5           | inactive        |
      | ADJ-008 | FL, GA          | cat, large_loss, property      | 0/3           | active          |

  Scenario: An adjuster at capacity is flagged
    When I visit the "adjusters" page
    Then "adjuster-at-capacity-ADJ-004" is visible
    And "adjuster-at-capacity-ADJ-001" is not visible

  Scenario: Filing a claim updates the assigned adjuster's load
    When I file a claim through the form with:
      | Claim number     | CLM-3104 |
      | Line of business | property |
      | Estimated loss   | 9000     |
      | Loss state       | NJ       |
    And I visit the "adjusters" page
    Then the "adjuster-row" rows show:
      | key     | adjuster-load |
      | ADJ-006 | 2/4           |

  # ---------------------------------------------------------------------------
  # Rules page (read-only, Q34)
  # ---------------------------------------------------------------------------

  Scenario: The rules page shows the active rules in evaluation order, ending with the fall-through
    When I visit the "rules" page
    Then the "rule-row" rows appear in this order:
      | key               |
      | cat_large_loss    |
      | luxury_auto       |
      | auto_fast_track   |
      | auto_standard     |
      | auto_complex      |
      | coastal_property  |
      | property_standard |
      | general_intake    |

  Scenario: Each rule shows its priority, conditions, queue and required skills
    When I visit the "rules" page
    Then the "rule-row" rows show:
      | key              | rule-priority | rule-conditions                                     | rule-queue       | rule-skills     |
      | luxury_auto      | 20            | line_of_business eq auto; vehicle_value gte 100000  | luxury_auto      | luxury_vehicle  |
      | coastal_property | 60            | line_of_business eq property; loss_state in TX,FL,LA | coastal_property | cat, property  |
      | general_intake   |               |                                                     | general_intake   |                 |

  Scenario: The rules page states that licensing is always enforced, and is read-only
    When I visit the "rules" page
    Then "licensing-guardrail" is visible
    And "rules-page" contains no form controls
