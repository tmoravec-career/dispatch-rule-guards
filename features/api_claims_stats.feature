@api
Feature: Claim statistics over the REST API
  As claims ops
  I want counts and total estimated loss per queue and per status
  So that I can see where the work and the money are without paging through every claim

  # Contract (OPEN_QUESTIONS.md Q43):
  #   GET /api/claims/stats   (any valid token: ops or adjuster)
  #   200 {
  #     "by_queue":  [{"queue", "count", "total_estimated_loss"}, ...],   sorted by queue name
  #     "by_status": [{"status", "count", "total_estimated_loss"}, ...],  "assigned", then "unassigned"
  #     "total":     {"count", "total_estimated_loss"}
  #   }
  #   by_queue always lists every configured queue plus general_intake, with zeros when empty
  #   (plus any other queue that still holds claims). by_status always lists both statuses.
  #   Computed with a single GROUP BY query over claims.

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
    And the API tokens:
      | token       | role     |
      | ops-token-1 | ops      |
      | adj-token-1 | adjuster |
    And I use the API token "ops-token-1"

  Scenario: An empty database returns zeros for every queue and status
    When I GET "/api/claims/stats"
    Then the response status is 200
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "by_queue" has these entries, in order:
      | queue             | count | total_estimated_loss |
      | auto_complex      | 0     | 0                    |
      | auto_fast_track   | 0     | 0                    |
      | auto_standard     | 0     | 0                    |
      | cat_large_loss    | 0     | 0                    |
      | coastal_property  | 0     | 0                    |
      | general_intake    | 0     | 0                    |
      | luxury_auto       | 0     | 0                    |
      | property_standard | 0     | 0                    |
    And the response JSON at "by_status" has these entries, in order:
      | status     | count | total_estimated_loss |
      | assigned   | 0     | 0                    |
      | unassigned | 0     | 0                    |
    And the response JSON at "total.count" is 0
    And the response JSON at "total.total_estimated_loss" is 0

  Scenario: Counts and loss totals per queue and per status, with empty queues as zeros
    Given these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-5001     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-5002     | auto             | 9000           | 135000        | false     | CA         |
      | CLM-5003     | auto             | 15000          | 110000        | false     | NV         |
      | CLM-5004     | property         | 8000           |               | false     | NY         |
      | CLM-5005     | liability        | 40000          |               | false     | WY         |
      | CLM-5006     | auto             | 3000           | 18000         | false     | TX         |
      | CLM-5007     | auto             | 14000          | 70000         | false     | TX         |
    When I GET "/api/claims/stats"
    Then the response status is 200
    And the response JSON at "by_queue" has these entries, in order:
      | queue             | count | total_estimated_loss |
      | auto_complex      | 0     | 0                    |
      | auto_fast_track   | 1     | 3000                 |
      | auto_standard     | 1     | 14000                |
      | cat_large_loss    | 0     | 0                    |
      | coastal_property  | 0     | 0                    |
      | general_intake    | 1     | 40000                |
      | luxury_auto       | 3     | 36000                |
      | property_standard | 1     | 8000                 |
    And the response JSON at "by_status" has these entries, in order:
      | status     | count | total_estimated_loss |
      | assigned   | 5     | 46000                |
      | unassigned | 2     | 55000                |
    And the response JSON at "total.count" is 7
    And the response JSON at "total.total_estimated_loss" is 101000
    And the response JSON at "total.total_estimated_loss" is of type "integer"

  Scenario: The stats agree with the sum of every page of the list endpoint
    Given these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-5101     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-5102     | auto             | 9000           | 135000        | false     | CA         |
      | CLM-5103     | auto             | 15000          | 110000        | false     | NV         |
      | CLM-5104     | property         | 8000           |               | false     | NY         |
      | CLM-5105     | liability        | 40000          |               | false     | WY         |
      | CLM-5106     | auto             | 3000           | 18000         | false     | TX         |
      | CLM-5107     | auto             | 14000          | 70000         | false     | TX         |
      | CLM-5108     | property         | 75000          |               | true      | FL         |
      | CLM-5109     | auto             | 40000          | 30000         | false     | AZ         |
    When I GET "/api/claims/stats"
    Then the response status is 200
    And the stats match the sums over every page of "/api/claims?per_page=2"

  Scenario: Stats are computed with a single grouped query
    Given these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-5201     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-5202     | property         | 8000           |               | false     | NY         |
    When I GET "/api/claims/stats"
    Then the response status is 200
    And the last request ran exactly 1 SQL query against "claims"

  @auth
  Scenario: An adjuster token can read the stats
    Given I use the API token "adj-token-1"
    When I GET "/api/claims/stats"
    Then the response status is 200
    And the response status and body agree

  Scenario: A queue removed from the rules is still listed while it holds claims
    # luxury_auto (3 claims) and cat_large_loss (no claims) are both removed from the active rules.
    # luxury_auto stays in by_queue because it still holds claims; cat_large_loss disappears.
    Given these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-5301     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-5302     | auto             | 9000           | 135000        | false     | CA         |
      | CLM-5303     | auto             | 15000          | 110000        | false     | NV         |
      | CLM-5304     | property         | 8000           |               | false     | NY         |
      | CLM-5305     | liability        | 40000          |               | false     | WY         |
      | CLM-5306     | auto             | 3000           | 18000         | false     | TX         |
      | CLM-5307     | auto             | 14000          | 70000         | false     | TX         |
    And the dispatch rules:
      | priority | id                | conditions                                          | queue             | required_skills  |
      | 30       | auto_fast_track   | line_of_business eq auto; estimated_loss lt 5000    | auto_fast_track   | auto             |
      | 40       | auto_standard     | line_of_business eq auto; estimated_loss lte 25000  | auto_standard     | auto             |
      | 50       | auto_complex      | line_of_business eq auto                            | auto_complex      | auto, large_loss |
      | 60       | coastal_property  | line_of_business eq property; loss_state in TX,FL,LA | coastal_property | property, cat    |
      | 70       | property_standard | line_of_business eq property                        | property_standard | property         |
    When I GET "/api/claims/stats"
    Then the response status is 200
    And the response JSON at "by_queue" has these entries, in order:
      | queue             | count | total_estimated_loss |
      | auto_complex      | 0     | 0                    |
      | auto_fast_track   | 1     | 3000                 |
      | auto_standard     | 1     | 14000                |
      | coastal_property  | 0     | 0                    |
      | general_intake    | 1     | 40000                |
      | luxury_auto       | 3     | 36000                |
      | property_standard | 1     | 8000                 |
    And the response JSON at "total.count" is 7
