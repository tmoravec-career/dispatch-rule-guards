@api
Feature: Dispatch REST API and dispatch webhook
  As a downstream system
  I want to create and dispatch claims over REST, get clear 4xx errors for bad input,
  and receive a signed, ordered, de-duplicable claim.assigned / claim.unassigned webhook
  whose shape is pinned by a JSON Schema
  So that I can integrate without guessing, and a webhook outage never stops claims being routed

  # Conventions (see docs/specs/STEP_GLOSSARY.md):
  #   - Right-hand side of "is" in JSON assertions is a JSON literal: "text", 123, true, null.
  #   - JSON paths are dotted, with [n] for array indexes: "errors[0].field".
  #   - "a valid claim" means this body, with the given claim_number:
  #       {"claim_number": "<n>", "line_of_business": "auto", "estimated_loss": 12000,
  #        "vehicle_value": 30000, "cat_event": false, "loss_state": "TX"}
  #   - The webhook contract lives at contracts/claim_dispatched.schema.json (Q23).
  #   - Every API request carries "Authorization: Bearer <token>" (OPEN_QUESTIONS.md Q39).
  #     The Background selects the ops token; auth scenarios switch token or send none.
  #     Roles: ops = read + create + re-dispatch; adjuster = read only.
  #   - Every JSON response, success or error, has Content-Type application/json.
  #   - "the response status and body agree" is the no-lying-status-codes invariant (Q44):
  #     a 2xx body never has an "errors" key; a 4xx body always has a non-empty "errors" array.
  #   - Webhooks are signed: X-Dispatch-Signature: sha256=<hex HMAC-SHA256 of the raw body> (Q45).
  #   - Rate limiting is per token (Q48). The test default is high enough never to trigger;
  #     the rate-limit scenarios lower it and drive a controllable clock (no sleeps).
  #   - Money fields accept JSON integers only (Q50).
  #   - GET /api/claims (list) is in api_claims_list.feature; GET /api/claims/stats is in
  #     api_claims_stats.feature.

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
    And the webhook endpoint responds with status 200
    And the webhook signing secret is "whsec_test_123"
    And the API tokens:
      | token       | role     |
      | ops-token-1 | ops      |
      | adj-token-1 | adjuster |
    And I use the API token "ops-token-1"

  # ---------------------------------------------------------------------------
  # Create and dispatch
  # ---------------------------------------------------------------------------

  Scenario: Creating a claim dispatches it and returns the explained result
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4001", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "CA"}
      """
    Then the response status is 201
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "claim.claim_number" is "CLM-4001"
    And the response JSON at "claim.vehicle_value" is 120000
    And the response JSON at "dispatch.status" is "assigned"
    And the response JSON at "dispatch.queue" is "luxury_auto"
    And the response JSON at "dispatch.matched_rule" is "luxury_auto"
    And the response JSON at "dispatch.adjuster_id" is "ADJ-004"
    And the response JSON at "dispatch.reason_code" is "assigned"
    And the response JSON at "dispatch.reason" is a non-empty string

  Scenario: A claim that cannot be assigned is still created, and says why
    Given adjuster "ADJ-004" has 2 open claims
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4002", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "CA"}
      """
    Then the response status is 201
    And the response status and body agree
    And the response JSON at "dispatch.status" is "unassigned"
    And the response JSON at "dispatch.queue" is "luxury_auto"
    And the response JSON at "dispatch.adjuster_id" is null
    And the response JSON at "dispatch.reason_code" is "qualified_adjusters_at_capacity"
    And the response JSON at "dispatch.reason" is a non-empty string

  Scenario: A claim matching no rule reports general_intake with a null matched rule
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4003", "line_of_business": "liability", "estimated_loss": 40000,
       "cat_event": false, "loss_state": "WY"}
      """
    Then the response status is 201
    And the response JSON at "dispatch.queue" is "general_intake"
    And the response JSON at "dispatch.matched_rule" is null
    And the response JSON at "dispatch.reason_code" is "no_qualified_adjuster"
    And the response JSON at "claim.vehicle_value" is null

  Scenario: Fetching a claim returns its latest dispatch result
    Given I POST to "/api/claims" a valid claim "CLM-4004"
    When I GET "/api/claims/CLM-4004"
    Then the response status is 200
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "claim.claim_number" is "CLM-4004"
    And the response JSON at "dispatch.queue" is "auto_standard"
    And the response JSON at "dispatch.adjuster_id" is "ADJ-001"

  # ---------------------------------------------------------------------------
  # Re-dispatch
  # ---------------------------------------------------------------------------

  Scenario: Re-dispatching a stranded claim after capacity frees up assigns it
    Given adjuster "ADJ-004" has 2 open claims
    And I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4010", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "NV"}
      """
    And adjuster "ADJ-004" has 1 open claim
    When I POST to "/api/claims/CLM-4010/dispatch"
    Then the response status is 200
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "dispatch.status" is "assigned"
    And the response JSON at "dispatch.adjuster_id" is "ADJ-004"
    And adjuster "ADJ-004" should have 2 open claims

  Scenario: Re-dispatching an assigned claim releases its previous assignment first
    Given I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4011", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "CA"}
      """
    When I POST to "/api/claims/CLM-4011/dispatch"
    Then the response status is 200
    And the response JSON at "dispatch.adjuster_id" is "ADJ-004"
    And adjuster "ADJ-004" should have 1 open claim

  Scenario: Re-dispatching uses the rules that are active now, not the ones at first dispatch
    Given I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4012", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "CA"}
      """
    And rule "luxury_auto" has condition "vehicle_value gte 150000"
    When I POST to "/api/claims/CLM-4012/dispatch"
    Then the response status is 200
    And the response JSON at "dispatch.queue" is "auto_standard"
    And the response JSON at "dispatch.matched_rule" is "auto_standard"
    And the response JSON at "dispatch.adjuster_id" is "ADJ-005"
    And adjuster "ADJ-004" should have 0 open claims
    And adjuster "ADJ-005" should have 1 open claim

  Scenario Outline: Unknown claims return 404
    When I <request>
    Then the response status is 404
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "not_found"

    Examples:
      | request                                  |
      | GET "/api/claims/CLM-9999"               |
      | POST to "/api/claims/CLM-9999/dispatch"  |

  # ---------------------------------------------------------------------------
  # Status codes never lie (Q44)
  # ---------------------------------------------------------------------------

  Scenario Outline: Success bodies never carry errors, and error bodies always do
    Given I POST to "/api/claims" a valid claim "CLM-4500"
    When I <request>
    Then the response status is <status>
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree

    Examples:
      | request                                                                     | status |
      | POST to "/api/claims" a valid claim "CLM-4501"                              | 201    |
      | GET "/api/claims/CLM-4500"                                                  | 200    |
      | POST to "/api/claims/CLM-4500/dispatch"                                     | 200    |
      | GET "/api/claims"                                                           | 200    |
      | GET "/api/claims/stats"                                                     | 200    |
      | POST to "/api/claims" a valid claim "CLM-4500"                              | 409    |
      | POST to "/api/claims" a valid claim "CLM-4502" with "loss_state" set to "ZZ" | 422    |
      | GET "/api/claims?page=0"                                                    | 422    |
      | GET "/api/claims/CLM-9999"                                                  | 404    |

  # ---------------------------------------------------------------------------
  # Authentication and roles (Q39). Auth is checked before anything else, so an
  # unauthenticated request for an unknown claim is 401, not 404.
  # ---------------------------------------------------------------------------

  @auth
  Scenario Outline: A request with no token is rejected with 401 and a Bearer challenge
    Given I send no API token
    When I <request>
    Then the response status is 401
    And the response header "WWW-Authenticate" starts with "Bearer"
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "unauthorized"
    And no webhook is sent

    Examples:
      | request                                        |
      | GET "/api/claims"                              |
      | GET "/api/claims/stats"                        |
      | GET "/api/claims/CLM-9999"                     |
      | POST to "/api/claims" a valid claim "CLM-4400" |
      | POST to "/api/claims/CLM-9999/dispatch"        |

  @auth
  Scenario Outline: An unknown or malformed token is rejected with 401
    Given I send the Authorization header "<header>"
    When I POST to "/api/claims" a valid claim "CLM-4401"
    Then the response status is 401
    And the response header "WWW-Authenticate" starts with "Bearer"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "unauthorized"
    And claim "CLM-4401" does not exist

    Examples:
      | header                     |
      | Bearer not-a-real-token    |
      | Bearer                     |
      | ops-token-1                |
      | Basic b3BzLXRva2VuLTE6     |
      | bearer OPS-TOKEN-1         |

  @auth
  Scenario: An adjuster token cannot create claims
    Given I use the API token "adj-token-1"
    When I POST to "/api/claims" a valid claim "CLM-4402"
    Then the response status is 403
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "forbidden"
    And claim "CLM-4402" does not exist
    And no webhook is sent

  @auth
  Scenario: An adjuster token cannot re-dispatch, and nothing changes
    Given I POST to "/api/claims" a valid claim "CLM-4403"
    And I use the API token "adj-token-1"
    When I POST to "/api/claims/CLM-4403/dispatch"
    Then the response status is 403
    And the response status and body agree
    And the response JSON at "errors[0].code" is "forbidden"
    And adjuster "ADJ-001" should have 1 open claim
    And 1 webhook has been sent

  @auth
  Scenario Outline: Each role gets success on the requests it is allowed to make
    Given I POST to "/api/claims" a valid claim "CLM-4404"
    And I use the API token "<token>"
    When I <request>
    Then the response status is <status>
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree

    Examples:
      | token       | request                                        | status |
      | ops-token-1 | POST to "/api/claims" a valid claim "CLM-4405" | 201    |
      | ops-token-1 | POST to "/api/claims/CLM-4404/dispatch"        | 200    |
      | ops-token-1 | GET "/api/claims/CLM-4404"                     | 200    |
      | ops-token-1 | GET "/api/claims"                              | 200    |
      | ops-token-1 | GET "/api/claims/stats"                        | 200    |
      | adj-token-1 | GET "/api/claims/CLM-4404"                     | 200    |
      | adj-token-1 | GET "/api/claims"                              | 200    |
      | adj-token-1 | GET "/api/claims/stats"                        | 200    |

  # ---------------------------------------------------------------------------
  # Rate limiting (Q48): per token, controllable clock, no sleeps
  # ---------------------------------------------------------------------------

  @rate_limit
  Scenario: The request after the limit gets 429 with Retry-After and an errors body
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And the API rate limit is 3 requests per 60 seconds
    When I GET "/api/claims" 3 times
    Then every response status was 200
    When the clock advances by 15 seconds
    And I GET "/api/claims"
    Then the response status is 429
    And the response header "Retry-After" is "45"
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "rate_limited"

  @rate_limit
  Scenario: Another token is unaffected in the same window
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And the API rate limit is 3 requests per 60 seconds
    When I GET "/api/claims" 4 times
    Then the response status is 429
    Given I use the API token "adj-token-1"
    When I GET "/api/claims"
    Then the response status is 200

  @rate_limit
  Scenario: Requests succeed again once the window resets
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And the API rate limit is 3 requests per 60 seconds
    When I GET "/api/claims" 4 times
    Then the response status is 429
    When the clock advances by 59 seconds
    And I GET "/api/claims"
    Then the response status is 429
    And the response header "Retry-After" is "1"
    When the clock advances by 1 second
    And I GET "/api/claims"
    Then the response status is 200

  @rate_limit
  Scenario: Error responses count toward the limit
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And the API rate limit is 3 requests per 60 seconds
    When I GET "/api/claims?page=0" 3 times
    Then every response status was 422
    When I GET "/api/claims"
    Then the response status is 429
    And the response status and body agree

  @rate_limit
  Scenario: Authentication is checked before the limiter, so a bad token always gets 401
    # Unauthenticated requests are rejected before rate limiting: they never get 429, and
    # they don't use up any real token's allowance.
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And the API rate limit is 3 requests per 60 seconds
    And I send the Authorization header "Bearer not-a-real-token"
    When I GET "/api/claims" 5 times
    Then every response status was 401
    Given I use the API token "ops-token-1"
    When I GET "/api/claims" 3 times
    Then every response status was 200

  @rate_limit
  Scenario: A rate-limited create creates nothing and sends no webhook
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And the API rate limit is 1 requests per 60 seconds
    When I POST to "/api/claims" a valid claim "CLM-4700"
    Then the response status is 201
    When I POST to "/api/claims" a valid claim "CLM-4701"
    Then the response status is 429
    And the response status and body agree
    And claim "CLM-4701" does not exist
    And 1 webhook has been sent

  # ---------------------------------------------------------------------------
  # 4xx handling for bad input
  # ---------------------------------------------------------------------------

  Scenario Outline: An invalid field value is rejected with 422 and a machine-readable error
    When I POST to "/api/claims" a valid claim "CLM-4100" with "<field>" set to <value>
    Then the response status is 422
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].field" is "<field>"
    And the response JSON at "errors[0].code" is "<code>"
    And claim "CLM-4100" does not exist
    And no webhook is sent

    Examples:
      | field            | value      | code           |
      | line_of_business | "boat"     | inclusion      |
      | estimated_loss   | "lots"     | invalid_value  |
      | estimated_loss   | "$1,200"   | invalid_value  |
      | estimated_loss   | "12000"    | invalid_value  |
      | estimated_loss   | -1         | out_of_range   |
      | estimated_loss   | 12000.5    | not_an_integer |
      | estimated_loss   | true       | invalid_value  |
      | estimated_loss   | null       | missing        |
      | vehicle_value    | "x"        | invalid_value  |
      | vehicle_value    | "$120,000" | invalid_value  |
      | vehicle_value    | []         | invalid_value  |
      | vehicle_value    | {}         | invalid_value  |
      | vehicle_value    | 99999.99   | not_an_integer |
      | cat_event        | "yes"      | not_a_boolean  |
      | loss_state       | "Texas"    | inclusion      |
      | loss_state       | "ZZ"       | inclusion      |
      | loss_state       | "tx"       | inclusion      |

  Scenario Outline: A missing required field is rejected with 422
    When I POST to "/api/claims" a valid claim "CLM-4101" without "<field>"
    Then the response status is 422
    And the response status and body agree
    And the response JSON at "errors[0].field" is "<field>"
    And the response JSON at "errors[0].code" is "missing"

    Examples:
      | field            |
      | claim_number     |
      | line_of_business |
      | estimated_loss   |
      | loss_state       |

  Scenario Outline: Optional fields may be omitted
    When I POST to "/api/claims" a valid claim "CLM-4102" without "<field>"
    Then the response status is 201
    And the response status and body agree

    Examples:
      | field         |
      | vehicle_value |
      | cat_event     |

  Scenario: An unknown field is rejected rather than silently ignored
    When I POST to "/api/claims" a valid claim "CLM-4103" with "vehicle_val" set to 120000
    Then the response status is 422
    And the response status and body agree
    And the response JSON at "errors[0].field" is "vehicle_val"
    And the response JSON at "errors[0].code" is "unknown_field"

  Scenario: All invalid fields are reported together
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4104", "line_of_business": "boat", "estimated_loss": "lots",
       "cat_event": false, "loss_state": "TX"}
      """
    Then the response status is 422
    And the response status and body agree
    And the response JSON at "errors" has 2 entries

  Scenario: Malformed JSON is rejected with 400
    When I POST to "/api/claims" with the raw body:
      """
      {"claim_number": "CLM-4105", "line_of_business": "auto",
      """
    Then the response status is 400
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "malformed_json"
    And no webhook is sent

  Scenario: A non-JSON content type is rejected with 415
    When I POST to "/api/claims" with content type "text/plain" and the raw body:
      """
      claim_number=CLM-4106
      """
    Then the response status is 415
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree

  Scenario: A duplicate claim number is rejected with 409 and the original is untouched
    Given I POST to "/api/claims" a valid claim "CLM-4107"
    When I POST to "/api/claims" a valid claim "CLM-4107"
    Then the response status is 409
    And the response header "Content-Type" starts with "application/json"
    And the response status and body agree
    And the response JSON at "errors[0].code" is "duplicate_claim_number"
    And adjuster "ADJ-001" should have 1 open claim

  # ---------------------------------------------------------------------------
  # Webhook: shape pinned by the JSON Schema contract
  # ---------------------------------------------------------------------------

  @contract
  Scenario: An assigned claim emits a claim.assigned webhook that conforms to the contract
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4200", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "CA"}
      """
    Then 1 webhook has been sent
    And the last webhook payload conforms to "contracts/claim_dispatched.schema.json"
    And the last webhook payload at "event" is "claim.assigned"
    And the last webhook payload at "claim.claim_number" is "CLM-4200"
    And the last webhook payload at "dispatch.queue" is "luxury_auto"
    And the last webhook payload at "dispatch.matched_rule" is "luxury_auto"
    And the last webhook payload at "dispatch.adjuster_id" is "ADJ-004"
    And the last webhook payload at "dispatch.reason_code" is "assigned"
    And the last webhook payload at "sequence" is 1

  @contract
  Scenario Outline: An unassigned claim emits a claim.unassigned webhook that conforms to the contract
    Given adjuster "ADJ-004" has <adj_004_open> open claims
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4201", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "<state>"}
      """
    Then 1 webhook has been sent
    And the last webhook payload conforms to "contracts/claim_dispatched.schema.json"
    And the last webhook payload at "event" is "claim.unassigned"
    And the last webhook payload at "dispatch.adjuster_id" is null
    And the last webhook payload at "dispatch.reason_code" is "<reason_code>"

    Examples:
      | state | adj_004_open | reason_code                     |
      | CA    | 2            | qualified_adjusters_at_capacity |
      | GA    | 0            | no_qualified_adjuster           |

  @contract
  Scenario: A fall-through claim's webhook carries a null matched rule and still conforms
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4202", "line_of_business": "liability", "estimated_loss": 40000,
       "cat_event": false, "loss_state": "TX"}
      """
    Then the last webhook payload conforms to "contracts/claim_dispatched.schema.json"
    And the last webhook payload at "dispatch.queue" is "general_intake"
    And the last webhook payload at "dispatch.matched_rule" is null

  @contract
  Scenario: Re-dispatching emits a new webhook with a new event ID
    Given I POST to "/api/claims" a valid claim "CLM-4203"
    When I POST to "/api/claims/CLM-4203/dispatch"
    Then 2 webhooks have been sent
    And every webhook payload conforms to "contracts/claim_dispatched.schema.json"
    And the webhook event IDs are all different

  @contract
  Scenario Outline: The contract rejects payloads that break the agreed shape
    Given a valid "<event>" webhook payload
    When I set "<path>" in the payload to <value>
    Then the payload does not conform to "contracts/claim_dispatched.schema.json"

    Examples:
      | event            | path                 | value          |
      | claim.assigned   | event                | "claim.routed" |
      | claim.assigned   | dispatch.adjuster_id | null           |
      | claim.unassigned | dispatch.adjuster_id | "ADJ-004"      |
      | claim.assigned   | dispatch.reason_code | "ok"           |
      | claim.unassigned | dispatch.reason_code | "assigned"     |
      | claim.assigned   | claim.estimated_loss | "12000"        |
      | claim.assigned   | occurred_at          | "yesterday"    |
      | claim.assigned   | sequence             | 0              |
      | claim.assigned   | sequence             | "1"            |
      | claim.assigned   | extra_field          | 1              |
      | claim.assigned   | dispatch.status      | "unassigned"   |
      | claim.unassigned | dispatch.status      | "assigned"     |

  @contract
  Scenario Outline: The contract requires every agreed field
    Given a valid "claim.assigned" webhook payload
    When I remove "<path>" from the payload
    Then the payload does not conform to "contracts/claim_dispatched.schema.json"

    Examples:
      | path                  |
      | event                 |
      | event_id              |
      | occurred_at           |
      | sequence              |
      | claim.claim_number    |
      | claim.loss_state      |
      | dispatch.status       |
      | dispatch.queue        |
      | dispatch.matched_rule |
      | dispatch.adjuster_id  |
      | dispatch.reason_code  |
      | dispatch.reason       |

  # ---------------------------------------------------------------------------
  # Webhook integrity (Q45-Q47): signature, de-duplication, ordering
  # ---------------------------------------------------------------------------

  @webhook_integrity
  Scenario: Every delivery is signed with an HMAC of the raw body
    When I POST to "/api/claims" a valid claim "CLM-4600"
    Then the last webhook has header "X-Dispatch-Signature" starting with "sha256="
    And the last webhook signature verifies with secret "whsec_test_123"
    And the last webhook signature does not verify with secret "some-other-secret"

  @webhook_integrity
  Scenario: A tampered body fails verification
    # The valid claim goes to ADJ-001. The tamper is a byte-level substitution on the raw body,
    # not a parse-and-re-serialise, so the only change is these bytes.
    When I POST to "/api/claims" a valid claim "CLM-4601"
    And the last webhook body is tampered with by replacing "ADJ-001" with "ADJ-999"
    Then the last webhook signature does not verify with secret "whsec_test_123"

  @webhook_integrity
  Scenario: The signature covers the raw bytes, so re-serialising the JSON breaks it
    # Consumers must verify the body exactly as received, before parsing it.
    When I POST to "/api/claims" a valid claim "CLM-4602"
    And the last webhook body is re-serialised with different whitespace
    Then the last webhook signature does not verify with secret "whsec_test_123"

  @webhook_integrity
  Scenario: The same delivery received twice is processed once
    Given a de-duplicating test consumer
    When I POST to "/api/claims" a valid claim "CLM-4603"
    And the last webhook is delivered to the test consumer 2 times
    Then the test consumer has processed 1 event
    And the test consumer has ignored 1 duplicate

  @webhook_integrity
  Scenario: De-duplication is by event, so a re-dispatch of the same claim is still processed
    Given a de-duplicating test consumer
    And I POST to "/api/claims" a valid claim "CLM-4604"
    When I POST to "/api/claims/CLM-4604/dispatch"
    And every webhook is delivered to the test consumer
    Then the test consumer has processed 2 events
    And the test consumer has ignored 0 duplicates

  @webhook_integrity
  Scenario: A dispatch then a re-dispatch produce events whose order consumers can trust
    Given the clock is frozen at "2026-10-06T09:00:00Z"
    And I POST to "/api/claims" a valid claim "CLM-4605"
    When the clock advances by 5 seconds
    And I POST to "/api/claims/CLM-4605/dispatch"
    Then 2 webhooks have been sent
    And the webhooks for claim "CLM-4605" have strictly increasing "sequence"
    And the webhooks for claim "CLM-4605" have strictly increasing "occurred_at"
    And the last webhook payload at "sequence" is 2
    And the last webhook payload at "occurred_at" is "2026-10-06T09:00:05.000Z"

  @webhook_integrity
  Scenario: The sequence is per claim
    Given I POST to "/api/claims" a valid claim "CLM-4606"
    And I POST to "/api/claims/CLM-4606/dispatch"
    When I POST to "/api/claims" a valid claim "CLM-4607"
    Then the last webhook payload at "claim.claim_number" is "CLM-4607"
    And the last webhook payload at "sequence" is 1

  # ---------------------------------------------------------------------------
  # Webhook failures never block routing
  # ---------------------------------------------------------------------------

  Scenario Outline: A failing webhook endpoint does not block or undo dispatch
    Given the webhook endpoint <failure>
    When I POST to "/api/claims" with JSON:
      """json
      {"claim_number": "CLM-4300", "line_of_business": "auto", "estimated_loss": 12000,
       "vehicle_value": 120000, "cat_event": false, "loss_state": "CA"}
      """
    Then the response status is 201
    And the response status and body agree
    And the response JSON at "dispatch.adjuster_id" is "ADJ-004"
    And adjuster "ADJ-004" should have 1 open claim
    And the webhook delivery for claim "CLM-4300" is recorded as "failed"

    Examples:
      | failure                    |
      | responds with status 500   |
      | responds with status 404   |
      | times out                  |
      | refuses connections        |

  Scenario: A webhook failure on re-dispatch does not block the re-dispatch
    Given I POST to "/api/claims" a valid claim "CLM-4301"
    And the webhook endpoint responds with status 503
    When I POST to "/api/claims/CLM-4301/dispatch"
    Then the response status is 200
    And the response JSON at "dispatch.status" is "assigned"

  Scenario: A successful delivery is recorded as delivered
    When I POST to "/api/claims" a valid claim "CLM-4302"
    Then the webhook delivery for claim "CLM-4302" is recorded as "delivered"

  Scenario: With no webhook URL configured, nothing is sent and dispatch still succeeds
    Given no webhook endpoint is configured
    When I POST to "/api/claims" a valid claim "CLM-4303"
    Then the response status is 201
    And the response JSON at "dispatch.status" is "assigned"
    And the response JSON at "dispatch.adjuster_id" is "ADJ-001"
    And adjuster "ADJ-001" should have 1 open claim
    And no webhook is sent
