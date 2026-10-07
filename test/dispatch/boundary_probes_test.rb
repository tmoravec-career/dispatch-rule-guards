require_relative "../test_helper"

# Boundary probes generated from both configs (Q29 and its follow-up).
class BoundaryProbesTest < Minitest::Test
  include DispatchFixtures

  def probes(base_hash, proposed_hash)
    Dispatch::Gate::BoundaryProbes.new(Dispatch::RulesConfig.from_h(base_hash),
                                       Dispatch::RulesConfig.from_h(proposed_hash)).probes
  end

  def values(list, field)
    list.select { |p| p.field == field }.map(&:value)
  end

  def test_every_threshold_probed_at_minus_one_value_plus_one
    list = probes(base_rules_hash, base_rules_hash)
    assert_equal [4_999, 5_000, 5_001, 24_999, 25_000, 25_001, 49_999, 50_000, 50_001], values(list, "estimated_loss")
    assert_equal [99_999, 100_000, 100_001], values(list, "vehicle_value")
  end

  def test_probes_are_sorted_and_unique_per_rule_field_and_value
    list = probes(base_rules_hash, demo_proposed_hash)
    keys = list.map { |p| [p.field, p.value, p.rule_id] }
    assert_equal keys.uniq, keys
    assert_equal keys.sort, keys
    assert_equal [59_999, 60_000, 60_001, 99_999, 100_000, 100_001], values(list, "vehicle_value")
  end

  # QA L1: a base rule and a proposed rule that share an id are different owners. The
  # base-only threshold keeps its own probes, built from the base rule's conditions.
  def test_same_rule_id_in_base_and_proposed_keeps_both_owners_probes
    base = { "rules" => [{ "id" => "big", "priority" => 10, "queue" => "big", "required_skills" => [], "conditions" => [
      { "field" => "line_of_business", "op" => "eq", "value" => "property" },
      { "field" => "estimated_loss", "op" => "gte", "value" => 50_000 }
    ] }] }
    proposed = with_condition(base, "big", "estimated_loss", "gte", 50_001)
    proposed["rules"][0]["conditions"][0]["value"] = "auto"
    list = probes(base, proposed).map { |p| [p.value, p.source, p.claim.line_of_business] }
    assert_equal [[49_999, :base, "property"], [50_000, :base, "property"], [50_000, :proposed, "auto"],
                  [50_001, :base, "property"], [50_001, :proposed, "auto"], [50_002, :proposed, "auto"]], list
  end

  def two_rule_hash(op)
    { "rules" => [
      { "id" => "big_property", "priority" => 10, "queue" => "big_property", "required_skills" => [],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "property" },
                         { "field" => "estimated_loss", "op" => "gte", "value" => 50_000 }] },
      { "id" => "big_auto", "priority" => 20, "queue" => "big_auto", "required_skills" => [],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                         { "field" => "estimated_loss", "op" => op, "value" => 50_001 }] }
    ] }
  end

  # Q55 / D3: colliding probe values from two rules each keep their own probe.
  def test_colliding_probe_values_from_different_rules_are_both_probed
    list = probes(two_rule_hash("gte"), two_rule_hash("gt"))
    assert_equal [[49_999, "big_property", "property"], [50_000, "big_auto", "auto"], [50_000, "big_property", "property"],
                  [50_001, "big_auto", "auto"], [50_001, "big_property", "property"], [50_002, "big_auto", "auto"]],
                 list.map { |p| [p.value, p.rule_id, p.claim.line_of_business] }
  end

  # Q55 G1: fractional thresholds are probed at whole dollars only.
  def test_fractional_thresholds_get_whole_dollar_probes
    rules = { "rules" => [{ "id" => "r", "priority" => 1, "queue" => "q", "required_skills" => [], "conditions" => [
      { "field" => "estimated_loss", "op" => "gt", "value" => 100.5 },
      { "field" => "vehicle_value", "op" => "gte", "value" => 2_000.0 }
    ] }] }
    list = probes(rules, rules)
    assert_equal [99, 100, 101, 102], values(list, "estimated_loss")
    assert_equal [1_999, 2_000, 2_001], values(list, "vehicle_value")
    assert(list.all? { |p| p.value.is_a?(Integer) })
    # The other condition is satisfied with a whole dollar too: gt 100.5 -> 101.
    assert_equal 101, list.find { |p| p.field == "vehicle_value" }.claim.estimated_loss
  end

  def test_probe_claim_starts_neutral_and_applies_owning_rules_other_conditions
    list = probes(base_rules_hash, base_rules_hash)
    cat = list.find { |p| p.field == "estimated_loss" && p.value == 50_000 }.claim
    assert_equal ["liability", 50_000, nil, true, "TX"],
                 [cat.line_of_business, cat.estimated_loss, cat.vehicle_value, cat.cat_event, cat.loss_state]
    lux = list.find { |p| p.field == "vehicle_value" && p.value == 99_999 }.claim
    assert_equal ["auto", 10_000, 99_999, false, "TX"],
                 [lux.line_of_business, lux.estimated_loss, lux.vehicle_value, lux.cat_event, lux.loss_state]
  end

  def test_other_condition_values_by_operator
    rules = { "rules" => [{ "id" => "r", "priority" => 1, "queue" => "q", "required_skills" => [], "conditions" => [
      { "field" => "loss_state", "op" => "in", "value" => %w[LA FL] },
      { "field" => "vehicle_value", "op" => "gt", "value" => 1_000 },
      { "field" => "line_of_business", "op" => "eq", "value" => "property" },
      { "field" => "estimated_loss", "op" => "lt", "value" => 500 }
    ] }] }
    list = probes(rules, rules)
    loss_probe = list.find { |p| p.field == "estimated_loss" && p.value == 500 }.claim
    assert_equal ["property", 500, 1_001, "LA"],
                 [loss_probe.line_of_business, loss_probe.estimated_loss, loss_probe.vehicle_value, loss_probe.loss_state]
    vehicle_probe = list.find { |p| p.field == "vehicle_value" && p.value == 1_000 }.claim
    assert_equal 499, vehicle_probe.estimated_loss
  end

  def test_shared_threshold_uses_the_proposed_owning_rule
    # Same threshold, but the proposed rule now also requires loss_state eq FL.
    proposed = deep_copy(base_rules_hash)
    proposed["rules"][0]["conditions"] << { "field" => "loss_state", "op" => "eq", "value" => "FL" }
    probe = probes(base_rules_hash, proposed).find { |p| p.field == "estimated_loss" && p.value == 50_000 }
    assert_equal "FL", probe.claim.loss_state
    assert_equal "cat_large_loss", probe.rule_id
  end

  def test_threshold_only_in_base_uses_the_base_rule
    proposed = deep_copy(base_rules_hash)
    proposed["rules"].reject! { |r| r["id"] == "auto_fast_track" }
    probe = probes(base_rules_hash, proposed).find { |p| p.field == "estimated_loss" && p.value == 4_999 }
    assert_equal ["auto_fast_track", "auto"], [probe.rule_id, probe.claim.line_of_business]
  end

  def test_threshold_only_in_proposed_is_probed
    proposed = deep_copy(base_rules_hash)
    proposed["rules"] << { "id" => "high_value_property", "priority" => 55, "queue" => "high_value_property",
                           "required_skills" => %w[property large_loss],
                           "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "property" },
                                            { "field" => "estimated_loss", "op" => "gte", "value" => 75_000 }] }
    assert_equal [74_999, 75_000, 75_001], values(probes(base_rules_hash, proposed), "estimated_loss") & [74_999, 75_000, 75_001]
  end

  def test_no_thresholds_no_probes
    assert_empty probes({ "rules" => [] }, { "rules" => [] })
  end
end
