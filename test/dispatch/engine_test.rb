require_relative "../test_helper"

# Routing, qualification, selection and explanations (features/dispatch_routing.feature).
class EngineTest < Minitest::Test
  include DispatchFixtures

  def setup
    @engine = Dispatch::Engine.new(base_config)
    @roster = roster
  end

  def dispatch(*args)
    @engine.dispatch(claim(*args), @roster)
  end

  # --- routing ---------------------------------------------------------------

  def test_single_matching_rule
    result = dispatch("CLM-1001", "auto", 12_000, 120_000, false, "CA")
    assert_equal ["luxury_auto", "luxury_auto", "ADJ-004"], [result.queue, result.matched_rule, result.adjuster_id]
  end

  def test_lowest_priority_number_wins
    result = dispatch("CLM-1002", "auto", 60_000, 150_000, true, "TX")
    assert_equal ["cat_large_loss", "ADJ-003"], [result.queue, result.adjuster_id]
  end

  def test_priority_not_config_order_decides
    rules = { "rules" => [
      { "id" => "auto_any", "priority" => 50, "queue" => "auto_any", "required_skills" => ["auto"],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" }] },
      { "id" => "luxury_auto", "priority" => 20, "queue" => "luxury_auto", "required_skills" => ["luxury_vehicle"],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                         { "field" => "vehicle_value", "op" => "gte", "value" => 100_000 }] }
    ] }
    engine = Dispatch::Engine.new(Dispatch::RulesConfig.from_h(rules))
    assert_equal "luxury_auto", engine.route(claim("CLM-1003", "auto", 9_000, 140_000, false, "TX")).rule_id
  end

  def test_conditions_are_anded
    result = dispatch("CLM-1004", "property", 8_000, 150_000, false, "NY")
    assert_equal ["property_standard", "ADJ-006"], [result.matched_rule, result.adjuster_id]
  end

  def test_in_operator_routing
    { "TX" => "coastal_property", "LA" => "coastal_property", "FL" => "coastal_property",
      "GA" => "property_standard", "NY" => "property_standard" }.each do |state, queue|
      assert_equal queue, @engine.route(claim("CLM-1005", "property", 8_000, nil, false, state)).queue, state
    end
  end

  def test_absent_field_falls_to_next_rule
    result = dispatch("CLM-1007", "auto", 12_000, nil, false, "TX")
    assert_equal ["auto_standard", "ADJ-001"], [result.matched_rule, result.adjuster_id]
  end

  def test_fall_through_to_general_intake
    result = dispatch("CLM-1010", "liability", 40_000, nil, false, "TX")
    assert_equal "general_intake", result.queue
    assert_nil result.matched_rule
    assert_equal ["ADJ-001", "assigned"], [result.adjuster_id, result.reason_code]
  end

  def test_general_intake_still_enforces_licensing
    result = dispatch("CLM-1011", "liability", 40_000, nil, false, "WY")
    assert_equal ["general_intake", nil, "no_qualified_adjuster"], [result.queue, result.adjuster_id, result.reason_code]
  end

  def test_empty_rule_set_sends_everything_to_general_intake
    engine = Dispatch::Engine.new(Dispatch::RulesConfig.from_h({ "rules" => [] }))
    result = engine.dispatch(claim("CLM-1012", "auto", 12_000, 120_000, false, "CA"), @roster)
    assert_equal ["general_intake", nil, "ADJ-004"], [result.queue, result.matched_rule, result.adjuster_id]
  end

  # --- boundaries ------------------------------------------------------------

  def test_thresholds_at_value_minus_one_value_plus_one
    [
      [["property", 49_999, nil, true, "TX"], "coastal_property"],
      [["property", 50_000, nil, true, "TX"], "cat_large_loss"],
      [["auto", 12_000, 99_999, false, "CA"], "auto_standard"],
      [["auto", 12_000, 100_000, false, "CA"], "luxury_auto"],
      [["auto", 4_999, 20_000, false, "TX"], "auto_fast_track"],
      [["auto", 5_000, 20_000, false, "TX"], "auto_standard"],
      [["auto", 25_000, 20_000, false, "TX"], "auto_standard"],
      [["auto", 25_001, 20_000, false, "TX"], "auto_complex"]
    ].each do |args, queue|
      assert_equal queue, @engine.route(claim("CLM-1070", *args)).queue, args.inspect
    end
  end

  # --- licensing guardrail ---------------------------------------------------

  def test_not_assigned_outside_licensed_states
    result = dispatch("CLM-1020", "auto", 12_000, 130_000, false, "GA")
    assert_equal ["luxury_auto", nil, "no_qualified_adjuster"], [result.queue, result.adjuster_id, result.reason_code]
  end

  def test_only_licensed_adjusters_considered_even_if_busier
    @roster.set_open_claims("ADJ-006", 3)
    assert_equal "ADJ-006", dispatch("CLM-1021", "property", 8_000, nil, false, "NY").adjuster_id
  end

  # --- skills ----------------------------------------------------------------

  def test_every_required_skill_is_needed
    assert_equal "ADJ-003", dispatch("CLM-1030", "property", 75_000, nil, true, "TX").adjuster_id
    result = dispatch("CLM-1031", "auto", 40_000, 30_000, false, "TX")
    assert_equal ["auto_complex", "no_qualified_adjuster"], [result.queue, result.reason_code]
  end

  def test_extra_skills_do_not_disqualify
    assert_equal "ADJ-008", dispatch("CLM-1032", "property", 8_000, nil, false, "FL").adjuster_id
  end

  # --- active / capacity -----------------------------------------------------

  def test_inactive_adjusters_never_assigned_and_full_pool_is_at_capacity
    @roster.set_open_claims("ADJ-004", 2)
    result = dispatch("CLM-1040", "auto", 12_000, 125_000, false, "CA")
    assert_equal [nil, "qualified_adjusters_at_capacity"], [result.adjuster_id, result.reason_code]
  end

  def test_only_otherwise_qualified_adjuster_inactive_means_nobody_qualified
    @roster.update("ADJ-004", active: false)
    assert_equal "no_qualified_adjuster", dispatch("CLM-1041", "auto", 12_000, 125_000, false, "NV").reason_code
  end

  def test_assignments_consume_capacity
    results = [["CLM-1042", 120_000, "CA"], ["CLM-1043", 135_000, "NV"], ["CLM-1044", 110_000, "AZ"]].map do |n, v, s|
      dispatch(n, "auto", 12_000, v, false, s)
    end
    assert_equal ["ADJ-004", "ADJ-004", nil], results.map(&:adjuster_id)
    assert_equal "qualified_adjusters_at_capacity", results.last.reason_code
    assert_equal 2, @roster.find("ADJ-004").open_claims
  end

  def test_unassigned_claim_consumes_no_capacity
    @roster.set_open_claims("ADJ-004", 2)
    dispatch("CLM-1045", "auto", 12_000, 120_000, false, "CA")
    assert_equal 2, @roster.find("ADJ-004").open_claims
  end

  def test_capacity_zero_is_qualified_but_full
    r = Dispatch::Roster.from_h({ "adjusters" => [
      { "id" => "ADJ-900", "name" => "Zero", "active" => true, "licensed_states" => ["TX"], "skills" => ["auto"],
        "capacity" => 0, "open_claims" => 0 }
    ] })
    result = @engine.dispatch(claim("C", "auto", 12_000, 30_000, false, "TX"), r)
    assert_equal "qualified_adjusters_at_capacity", result.reason_code
  end

  # --- balancing -------------------------------------------------------------

  def two_adjusters(a, b)
    Dispatch::Roster.from_h({ "adjusters" => [a, b].map do |id, cap, open|
      { "id" => id, "name" => id, "active" => true, "licensed_states" => ["TX"], "skills" => ["auto"],
        "capacity" => cap, "open_claims" => open }
    end })
  end

  def test_lowest_utilization_not_fewest_open_claims
    r = two_adjusters(["ADJ-101", 10, 3], ["ADJ-102", 2, 1])
    assert_equal "ADJ-101", @engine.dispatch(claim("CLM-1050", "auto", 12_000, 30_000, false, "TX"), r).adjuster_id
  end

  def test_tie_breaks_by_id_regardless_of_roster_order
    r = two_adjusters(["ADJ-202", 2, 1], ["ADJ-201", 4, 2])
    assert_equal "ADJ-201", @engine.dispatch(claim("CLM-1051", "auto", 12_000, 30_000, false, "TX"), r).adjuster_id
  end

  def test_utilization_compared_exactly
    r = two_adjusters(["ADJ-302", 3, 1], ["ADJ-301", 6, 2])
    assert_equal "ADJ-301", @engine.dispatch(claim("CLM-1052", "auto", 12_000, 30_000, false, "TX"), r).adjuster_id
  end

  def test_consecutive_claims_alternate
    ids = [["CLM-1053", "TX"], ["CLM-1054", "FL"], ["CLM-1055", "TX"], ["CLM-1056", "TX"]].map do |n, s|
      dispatch(n, "auto", 12_000, 30_000, false, s).adjuster_id
    end
    assert_equal %w[ADJ-001 ADJ-002 ADJ-001 ADJ-002], ids
  end

  def test_at_capacity_only_when_every_qualified_adjuster_full
    [[3, 2, "ADJ-002", "assigned"], [2, 3, "ADJ-001", "assigned"], [3, 3, nil, "qualified_adjusters_at_capacity"]].each do |a, b, adj, code|
      r = roster
      r.set_open_claims("ADJ-001", a)
      r.set_open_claims("ADJ-002", b)
      result = @engine.dispatch(claim("CLM-1062", "auto", 12_000, 120_000, false, "TX"), r)
      assert_equal [adj, code], [result.adjuster_id, result.reason_code]
    end
  end

  def test_no_qualified_wins_over_at_capacity
    @roster.set_open_claims("ADJ-001", 3)
    @roster.set_open_claims("ADJ-002", 3)
    assert_equal "no_qualified_adjuster", dispatch("CLM-1061", "auto", 12_000, 120_000, false, "GA").reason_code
  end

  def test_deterministic_against_fresh_roster_copy
    snapshot = @roster.copy
    first = dispatch("CLM-1057", "auto", 12_000, 30_000, false, "TX")
    second = @engine.dispatch(claim("CLM-1057", "auto", 12_000, 30_000, false, "TX"), snapshot)
    assert_equal first.to_h, second.to_h
  end

  # --- decide / exclusion seam for phase 3 -----------------------------------

  def test_decide_does_not_mutate_roster
    result = @engine.decide(claim("C", "auto", 12_000, 120_000, false, "CA"), @roster)
    assert_equal "ADJ-004", result.adjuster_id
    assert_equal 0, @roster.find("ADJ-004").open_claims
  end

  def test_exclusion_list_reselects_next_best_candidate
    c = claim("C", "auto", 12_000, 30_000, false, "TX")
    assert_equal "ADJ-001", @engine.decide(c, @roster).adjuster_id
    assert_equal "ADJ-002", @engine.decide(c, @roster, exclude: ["ADJ-001"]).adjuster_id
    exhausted = @engine.decide(c, @roster, exclude: %w[ADJ-001 ADJ-002])
    assert_nil exhausted.adjuster_id
    assert_equal "qualified_adjusters_at_capacity", exhausted.reason_code
  end

  # Review L1: exclude takes an Array, a Set, a single ID or nil, and matches whole IDs.
  def test_exclusion_accepts_set_single_id_and_nil
    require "set"
    c = claim("C", "auto", 12_000, 30_000, false, "TX")
    assert_equal "ADJ-002", @engine.decide(c, @roster, exclude: Set["ADJ-001"]).adjuster_id
    assert_equal "ADJ-002", @engine.decide(c, @roster, exclude: "ADJ-001").adjuster_id
    assert_equal "ADJ-001", @engine.decide(c, @roster, exclude: "ADJ-00").adjuster_id, "no substring match"
    assert_equal "ADJ-001", @engine.decide(c, @roster, exclude: nil).adjuster_id
  end

  # Review L4: capacity 0 is full, never a ZeroDivisionError.
  def test_capacity_zero_utilization_is_full
    zero = Dispatch::Adjuster.from_h("id" => "ADJ-900", "name" => "Zero", "active" => true, "licensed_states" => ["TX"],
                                     "skills" => [], "capacity" => 0, "open_claims" => 0)
    assert_equal Rational(1), zero.utilization
    assert zero.full?
  end

  def test_candidates_are_ordered_for_reselection
    c = claim("C", "auto", 12_000, 30_000, false, "TX")
    @roster.set_open_claims("ADJ-001", 1)
    assert_equal %w[ADJ-002 ADJ-001], @engine.candidates(c, @roster).map(&:id)
  end

  def test_roster_refuses_to_overfill
    @roster.set_open_claims("ADJ-004", 2)
    assert_raises(Dispatch::CapacityError) { @roster.assign!("ADJ-004") }
  end

  # --- explanations ----------------------------------------------------------

  def test_every_result_has_a_reason
    [[0, "CA", "assigned"], [2, "CA", "qualified_adjusters_at_capacity"], [0, "GA", "no_qualified_adjuster"]].each do |open, state, code|
      r = roster
      r.set_open_claims("ADJ-004", open)
      result = @engine.dispatch(claim("CLM-1060", "auto", 12_000, 120_000, false, state), r)
      assert_equal ["luxury_auto", code], [result.matched_rule, result.reason_code]
      assert_kind_of String, result.reason
      refute_empty result.reason.strip
    end
  end

  def test_result_to_h
    result = dispatch("CLM-1001", "auto", 12_000, 120_000, false, "CA")
    assert_equal({ "claim_number" => "CLM-1001", "status" => "assigned", "queue" => "luxury_auto",
                   "matched_rule" => "luxury_auto", "adjuster_id" => "ADJ-004", "reason_code" => "assigned",
                   "reason" => result.reason }, result.to_h)
  end
end
