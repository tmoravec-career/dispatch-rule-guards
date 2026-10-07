@load
Feature: Load behaviour and the capacity audit
  As engineering / QA
  I want proof that dispatch never over-assigns an adjuster, even under concurrent load
  So that the read-then-write race in dispatch can't silently overload adjusters in production

  # Dispatch reads eligible adjusters and then writes an assignment, so two concurrent requests
  # can both see the last free slot. The capacity audit is the backstop: after any load run it
  # fails if ANY adjuster has open_claims > capacity. (OPEN_QUESTIONS.md Q37, Q40)
  #
  # The k6 script's own requirements (profiles, thresholds, checks, think time, the p95 comment)
  # are code-review criteria, not runtime behaviour, so they live in docs/specs/LOAD_TEST_CRITERIA.md.
  # This feature covers what can be executed:
  #   @audit        the audit CLI itself (fast, runs in the normal acceptance job)
  #   @concurrency  a deterministic race test against the real app and DB (acceptance job).
  #                 Deterministic because of a test-only seam: after candidate selection, every
  #                 thread blocks until all N threads have read, so they all race for the same
  #                 slots (STEP_GLOSSARY.md section 9).
  #   @k6_pr        the smoke profile; gates every PR (k6 CI job)
  #   @k6_nightly   load, storm, soak, stress and the latency check (nightly k6 job)
  #   Neither k6 tag runs in the default Cucumber profile.
  #
  # Concurrency rule under test (Q37): the capacity claim is an atomic conditional
  #   UPDATE adjusters SET open_claims = open_claims + 1 WHERE id = ? AND open_claims < capacity
  # If it updates 0 rows, the slot was lost: dispatch re-selects among the remaining qualified
  # adjusters and retries. qualified_adjusters_at_capacity is returned only when every
  # qualified adjuster is full.

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
  # Capacity audit
  # ---------------------------------------------------------------------------

  @audit
  Scenario: The audit passes when every adjuster is within capacity
    Given these claims have been dispatched in order:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-6001     | auto             | 12000          | 120000        | false     | CA         |
      | CLM-6002     | auto             | 9000           | 135000        | false     | CA         |
      | CLM-6003     | auto             | 15000          | 110000        | false     | NV         |
    When I run the capacity audit
    Then the capacity audit exits with status 0
    And the capacity audit reports no violations

  @audit @boundary
  Scenario Outline: The audit fails only when open_claims is greater than capacity
    # ADJ-004 has capacity 2. The counter is set directly to simulate what a lost race leaves behind.
    Given adjuster "ADJ-004" has <open> open claims
    When I run the capacity audit
    Then the capacity audit exits with status <status>

    Examples:
      | open | status |
      | 1    | 0      |
      | 2    | 0      |
      | 3    | 1      |

  @audit
  Scenario: The audit names every over-assigned adjuster
    Given adjuster "ADJ-004" has 3 open claims
    And adjuster "ADJ-001" has 5 open claims
    And adjuster "ADJ-002" has 3 open claims
    When I run the capacity audit
    Then the capacity audit exits with status 1
    And the capacity audit reports these violations:
      | adjuster | open_claims | capacity |
      | ADJ-001  | 5           | 3        |
      | ADJ-004  | 3           | 2        |

  @audit
  Scenario: Inactive adjusters are audited too
    Given adjuster "ADJ-007" has 6 open claims
    When I run the capacity audit
    Then the capacity audit exits with status 1
    And the capacity audit reports these violations:
      | adjuster | open_claims | capacity |
      | ADJ-007  | 6           | 5        |

  # ---------------------------------------------------------------------------
  # The race itself
  # ---------------------------------------------------------------------------

  @concurrency
  Scenario: Concurrent dispatches for one scarce adjuster never exceed capacity
    # 20 simultaneous CA luxury claims; ADJ-004 is the only qualified adjuster and has 2 slots.
    When 20 copies of this claim are dispatched concurrently:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-7000     | auto             | 12000          | 120000        | false     | CA         |
    Then 2 of them are assigned to adjuster "ADJ-004"
    And 18 of them are unassigned with reason code "qualified_adjusters_at_capacity"
    And adjuster "ADJ-004" should have 2 open claims
    When I run the capacity audit
    Then the capacity audit exits with status 0

  @concurrency
  Scenario: Concurrent dispatches spread across a pool and fill it exactly
    # TX auto_standard: ADJ-001 and ADJ-002, capacity 3 each = 6 slots for 10 claims.
    # With the seam, all 10 threads first pick the same least-utilized adjuster; the losers of
    # each conditional UPDATE re-select among the remaining qualified adjusters, so the pool
    # fills exactly and only the 4 claims beyond the 6 slots end up unassigned.
    When 10 copies of this claim are dispatched concurrently:
      | claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state |
      | CLM-7100     | auto             | 12000          | 30000         | false     | TX         |
    Then 3 of them are assigned to adjuster "ADJ-001"
    And 3 of them are assigned to adjuster "ADJ-002"
    And 4 of them are unassigned with reason code "qualified_adjusters_at_capacity"
    When I run the capacity audit
    Then the capacity audit exits with status 0

  # ---------------------------------------------------------------------------
  # k6 runs (k6 CI jobs only): @k6_pr on every PR, @k6_nightly nightly
  # ---------------------------------------------------------------------------

  @k6_pr
  Scenario: The smoke profile passes its thresholds and leaves no adjuster over capacity
    Given the app is running with the seed roster and rules
    When I run the k6 "smoke" profile
    Then k6 exits with status 0
    And the k6 summary reports threshold "http_req_failed" as "passed"
    And the k6 summary reports threshold "http_req_duration" as "passed"
    And the k6 summary reports threshold "checks" as "passed"
    When I run the capacity audit
    Then the capacity audit exits with status 0

  @k6_nightly
  Scenario Outline: Every nightly gating profile passes its thresholds and leaves no adjuster over capacity
    # Profile shapes are in docs/specs/LOAD_TEST_CRITERIA.md. soak runs with its short CI default.
    Given the app is running with the seed roster and rules
    When I run the k6 "<profile>" profile
    Then k6 exits with status 0
    And the k6 summary reports threshold "http_req_failed" as "passed"
    And the k6 summary reports threshold "http_req_duration" as "passed"
    And the k6 summary reports threshold "checks" as "passed"
    When I run the capacity audit
    Then the capacity audit exits with status 0

    Examples:
      | profile |
      | load    |
      | storm   |
      | soak    |

  @k6_nightly
  Scenario: The storm profile's CAT burst leaves every claim with a terminal result
    # Baseline, then a sudden burst of CAT property claims in TX/FL/LA, then recovery.
    Given the app is running with the seed roster and rules
    When I run the k6 "storm" profile
    Then k6 exits with status 0
    And every claim created during the k6 run has a terminal dispatch result
    And the k6 run created CAT-event property claims in each of "TX, FL, LA"
    When I run the capacity audit
    Then the capacity audit exits with status 0

  @k6_nightly
  Scenario: The soak duration is configurable
    Given the app is running with the seed roster and rules
    When I run the k6 "soak" profile with duration "90s"
    Then k6 exits with status 0
    And the k6 run lasted between 90 and 120 seconds

  @k6_nightly
  Scenario: The stress run reports a breaking point but never fails CI on thresholds
    Given the app is running with the seed roster and rules
    When I run the stress runner
    Then the stress runner exits with status 0
    And the stress report includes "breaking_point_vus"
    And the stress report includes "first_failed_threshold"
    When I run the capacity audit
    Then the capacity audit exits with status 0

  @k6_nightly
  Scenario: The stress runner still exits 0 when thresholds break early
    Given the app is running with the seed roster and rules
    And the app adds 500 ms of latency to every API response
    When I run the stress runner
    Then the stress runner exits with status 0
    And the stress report at "breaking_point_vus" is 10
    And the stress report at "first_failed_threshold" is "http_req_duration"

  @k6_nightly
  Scenario: A latency threshold breach fails the k6 run through thresholds alone
    # k6 exits 99 when a threshold fails. The script has no fail()/abort/exit of its own.
    Given the app is running with the seed roster and rules
    And the app adds 500 ms of latency to every API response
    When I run the k6 "smoke" profile
    Then k6 exits with status 99
    And the k6 summary reports threshold "http_req_duration" as "failed"
    And the k6 summary reports threshold "http_req_failed" as "passed"
