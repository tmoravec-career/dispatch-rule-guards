@api
Feature: Listing claims over the REST API
  As a downstream system or an adjuster's tooling
  I want to list claims with filters and pagination
  So that I can find work by queue, status, adjuster or state without pulling everything

  # Contract (OPEN_QUESTIONS.md Q38):
  #   GET /api/claims?queue=&status=&adjuster_id=&loss_state=&page=&per_page=
  #   200 {"page", "per_page", "total", "total_pages", "data": [ {claim, dispatch}, ... ]}
  #   Newest first. per_page defaults to 25, max 100. page starts at 1.
  #   total_pages = ceil(total / per_page); 0 when total is 0.
  #   A page past the end is 200 with "data": []. Invalid filter or paging values are 422.
  #   Each entry has the same shape as GET /api/claims/:claim_number, and conforms to
  #   contracts/claim_resource.schema.json.
  #
  # The Background dispatches 7 claims through the app (not over HTTP), oldest first, so the
  # newest-first order is CLM-5007 down to CLM-5001.

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
    And no webhook endpoint is configured
    And these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-5001     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-5002     | auto             | 9000           | 135000        | false     | CA         |
      | CLM-5003     | auto             | 15000          | 110000        | false     | NV         |
      | CLM-5004     | property         | 8000           |               | false     | NY         |
      | CLM-5005     | liability        | 40000          |               | false     | WY         |
      | CLM-5006     | auto             | 3000           | 18000         | false     | TX         |
      | CLM-5007     | auto             | 14000          | 70000         | false     | TX         |
    And the API tokens:
      | token       | role     |
      | ops-token-1 | ops      |
      | adj-token-1 | adjuster |
    And I use the API token "ops-token-1"

  # ---------------------------------------------------------------------------
  # Default listing: status, content type, envelope, order, shape
  # ---------------------------------------------------------------------------

  Scenario: Listing with no parameters returns every claim, newest first, with the paging envelope
    When I GET "/api/claims"
    Then the response status is 200
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "page" is 1
    And the response JSON at "per_page" is 25
    And the response JSON at "total" is 7
    And the response JSON at "total_pages" is 1
    And the response pagination is consistent
    And the response JSON at "data" has these entries, in order:
      | claim.claim_number | dispatch.status | dispatch.queue    | dispatch.adjuster_id | dispatch.reason_code            |
      | CLM-5007           | assigned        | auto_standard     | ADJ-002              | assigned                        |
      | CLM-5006           | assigned        | auto_fast_track   | ADJ-001              | assigned                        |
      | CLM-5005           | unassigned      | general_intake    |                      | no_qualified_adjuster           |
      | CLM-5004           | assigned        | property_standard | ADJ-006              | assigned                        |
      | CLM-5003           | unassigned      | luxury_auto       |                      | qualified_adjusters_at_capacity |
      | CLM-5002           | assigned        | luxury_auto       | ADJ-004              | assigned                        |
      | CLM-5001           | assigned        | luxury_auto       | ADJ-004              | assigned                        |

  Scenario: Envelope and entry fields have the agreed types
    When I GET "/api/claims"
    Then the response JSON at "page" is of type "integer"
    And the response JSON at "per_page" is of type "integer"
    And the response JSON at "total" is of type "integer"
    And the response JSON at "total_pages" is of type "integer"
    And the response JSON at "data" is of type "array"
    And every entry in the response JSON at "data" conforms to "contracts/claim_resource.schema.json"
    And the response JSON at "data[0].claim.claim_number" is of type "string"
    And the response JSON at "data[0].claim.estimated_loss" is of type "integer"
    And the response JSON at "data[0].claim.vehicle_value" is of type "integer"
    And the response JSON at "data[0].claim.cat_event" is of type "boolean"
    And the response JSON at "data[0].dispatch.matched_rule" is of type "string"
    And the response JSON at "data[2].dispatch.matched_rule" is of type "null"
    And the response JSON at "data[2].dispatch.adjuster_id" is of type "null"
    And the response JSON at "data[3].claim.vehicle_value" is of type "null"

  @auth
  Scenario: An adjuster token can list claims
    Given I use the API token "adj-token-1"
    When I GET "/api/claims"
    Then the response status is 200
    And the response JSON at "total" is 7

  @auth
  Scenario: Listing without a token is rejected
    Given I send no API token
    When I GET "/api/claims"
    Then the response status is 401
    And the response header "WWW-Authenticate" starts with "Bearer"
    And the response status and body agree

  # ---------------------------------------------------------------------------
  # Filters: every returned row matches, and nothing matching is left out
  # ---------------------------------------------------------------------------

  Scenario Outline: A filter returns exactly the claims that match it
    When I GET "/api/claims?<query>"
    Then the response status is 200
    And the response header "Content-Type" starts with "application/json"
    And every entry in the response JSON at "data" has "<path>" equal to <value>
    And the response JSON at "total" is <total>
    And the response JSON at "data" has <total> entries
    And the response pagination is consistent

    Examples:
      | query                     | path                 | value            | total |
      | queue=luxury_auto         | dispatch.queue       | "luxury_auto"    | 3     |
      | queue=general_intake      | dispatch.queue       | "general_intake" | 1     |
      | status=unassigned         | dispatch.status      | "unassigned"     | 2     |
      | status=assigned           | dispatch.status      | "assigned"       | 5     |
      | adjuster_id=ADJ-004       | dispatch.adjuster_id | "ADJ-004"        | 2     |
      | loss_state=TX             | claim.loss_state     | "TX"             | 2     |

  Scenario: Filters combine with AND
    When I GET "/api/claims?queue=luxury_auto&status=unassigned"
    Then the response status is 200
    And the response JSON at "total" is 1
    And the response JSON at "data" has these entries, in order:
      | claim.claim_number | dispatch.queue | dispatch.status |
      | CLM-5003           | luxury_auto    | unassigned      |

  Scenario: A valid filter with no matches returns an empty page, not an error
    When I GET "/api/claims?queue=cat_large_loss"
    Then the response status is 200
    And the response status and body agree
    And the response JSON at "total" is 0
    And the response JSON at "total_pages" is 0
    And the response JSON at "data" is []

  Scenario: A queue removed from the rules can still be filtered while it holds claims
    # Decision (Q35): the UI and API offer every configured queue, general_intake, and any
    # queue that still holds claims. CLM-5001..5003 stay in luxury_auto after the rule goes.
    Given the dispatch rules:
      | priority | id                | conditions                                          | queue             | required_skills  |
      | 10       | cat_large_loss    | cat_event eq true; estimated_loss gte 50000         | cat_large_loss    | cat, large_loss  |
      | 30       | auto_fast_track   | line_of_business eq auto; estimated_loss lt 5000    | auto_fast_track   | auto             |
      | 40       | auto_standard     | line_of_business eq auto; estimated_loss lte 25000  | auto_standard     | auto             |
      | 50       | auto_complex      | line_of_business eq auto                            | auto_complex      | auto, large_loss |
      | 60       | coastal_property  | line_of_business eq property; loss_state in TX,FL,LA | coastal_property | property, cat    |
      | 70       | property_standard | line_of_business eq property                        | property_standard | property         |
    When I GET "/api/claims?queue=luxury_auto"
    Then the response status is 200
    And the response status and body agree
    And the response JSON at "total" is 3
    And every entry in the response JSON at "data" has "dispatch.queue" equal to "luxury_auto"

  # ---------------------------------------------------------------------------
  # Pagination math
  # ---------------------------------------------------------------------------

  Scenario Outline: total_pages is ceil(total / per_page) and the last page holds the remainder
    When I GET "/api/claims?per_page=<per_page>"
    Then the response status is 200
    And the response JSON at "total" is 7
    And the response JSON at "total_pages" is <total_pages>
    And the response pagination is consistent
    When I GET "/api/claims?per_page=<per_page>&page=<total_pages>"
    Then the response status is 200
    And the response JSON at "page" is <total_pages>
    And the response JSON at "data" has <last_page_entries> entries
    And the response pagination is consistent

    Examples:
      | per_page | total_pages | last_page_entries |
      | 1        | 7           | 1                 |
      | 2        | 4           | 1                 |
      | 3        | 3           | 1                 |
      | 5        | 2           | 2                 |
      | 7        | 1           | 7                 |
      | 100      | 1           | 7                 |

  Scenario: Walking the pages returns each claim exactly once, newest first
    When I GET "/api/claims?per_page=3&page=1"
    Then the response JSON at "data" has these entries, in order:
      | claim.claim_number |
      | CLM-5007           |
      | CLM-5006           |
      | CLM-5005           |
    When I GET "/api/claims?per_page=3&page=2"
    Then the response JSON at "data" has these entries, in order:
      | claim.claim_number |
      | CLM-5004           |
      | CLM-5003           |
      | CLM-5002           |
    When I GET "/api/claims?per_page=3&page=3"
    Then the response JSON at "data" has these entries, in order:
      | claim.claim_number |
      | CLM-5001           |

  Scenario Outline: A page past the end is 200 with no data
    When I GET "/api/claims?<query>"
    Then the response status is 200
    And the response header "Content-Type" starts with "application/json"
    And the response JSON at "page" is <page>
    And the response JSON at "total" is <total>
    And the response JSON at "data" is []

    Examples:
      | query                               | page | total |
      | per_page=3&page=4                   | 4    | 7     |
      | page=2                              | 2    | 7     |
      | queue=cat_large_loss&page=2         | 2    | 0     |

  Scenario: Filters and pagination work together
    When I GET "/api/claims?queue=luxury_auto&per_page=2&page=2"
    Then the response status is 200
    And the response JSON at "total" is 3
    And the response JSON at "total_pages" is 2
    And the response JSON at "data" has these entries, in order:
      | claim.claim_number |
      | CLM-5001           |

  # ---------------------------------------------------------------------------
  # Invalid filters and paging
  # ---------------------------------------------------------------------------

  Scenario Outline: An invalid filter or paging value is rejected with 422
    When I GET "/api/claims?<query>"
    Then the response status is 422
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].field" is "<field>"
    And the response JSON at "errors[0].code" is "<code>"

    Examples:
      | query                  | field       | code           |
      | page=0                 | page        | out_of_range   |
      | page=-1                | page        | out_of_range   |
      | page=abc               | page        | not_an_integer |
      | per_page=0             | per_page    | out_of_range   |
      | per_page=101           | per_page    | out_of_range   |
      | per_page=2.5           | per_page    | not_an_integer |
      | status=pending         | status      | inclusion      |
      | queue=no_such_queue    | queue       | inclusion      |
      | adjuster_id=ADJ-999    | adjuster_id | inclusion      |
      | loss_state=Texas       | loss_state  | inclusion      |
      | loss_state=tx          | loss_state  | inclusion      |
      | sort=oldest            | sort        | unknown_field  |

  Scenario: Several invalid parameters are reported together
    When I GET "/api/claims?page=0&status=pending"
    Then the response status is 422
    And the response status and body agree
    And the response JSON at "errors" has 2 entries

  # ---------------------------------------------------------------------------
  # The list-entry contract: contracts/claim_resource.schema.json (Q38)
  # {claim, dispatch}, reusing the claim/dispatch definitions from the webhook
  # contract via $ref, additionalProperties false at every level.
  # ---------------------------------------------------------------------------

  @contract
  Scenario Outline: The claim resource contract rejects entries that break the agreed shape
    # "a valid claim resource payload" first asserts the untouched sample conforms.
    # The sample is an assigned claim (status "assigned", adjuster_id "ADJ-004", reason_code
    # "assigned"). The status rules live in $defs/dispatch (Q23), so this contract enforces them too.
    Given a valid claim resource payload
    When I set "<path>" in the payload to <value>
    Then the payload does not conform to "contracts/claim_resource.schema.json"

    Examples:
      | path                    | value                             |
      | event                   | "claim.assigned"                  |
      | extra_field             | 1                                 |
      | claim.extra_field       | 1                                 |
      | dispatch.extra_field    | 1                                 |
      | claim.estimated_loss    | "12000"                           |
      | claim.cat_event         | "false"                           |
      | dispatch.status         | "pending"                         |
      | dispatch.reason_code    | "ok"                              |
      | dispatch.adjuster_id    | 42                                |
      | dispatch.adjuster_id    | null                              |
      | dispatch.reason_code    | "qualified_adjusters_at_capacity" |
      | dispatch.status         | "unassigned"                      |

  @contract
  Scenario Outline: The claim resource contract requires both parts and their fields
    Given a valid claim resource payload
    When I remove "<path>" from the payload
    Then the payload does not conform to "contracts/claim_resource.schema.json"

    Examples:
      | path                  |
      | claim                 |
      | dispatch              |
      | claim.claim_number    |
      | claim.loss_state      |
      | dispatch.queue        |
      | dispatch.matched_rule |
      | dispatch.reason_code  |
