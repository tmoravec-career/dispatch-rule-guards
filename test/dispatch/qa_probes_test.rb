require_relative "../test_helper"

# QA re-verify of the rewritten boundary probes (Q29, Q55): gaps left by surviving mutants.
class QaProbesTest < Minitest::Test
  def config(*rules)
    Dispatch::RulesConfig.from_h({ "rules" => rules.each_with_index.map do |(id, conditions), i|
      { "id" => id, "priority" => (i + 1) * 10, "queue" => id, "required_skills" => [], "conditions" => conditions }
    end })
  end

  def cond(field, op, value)
    { "field" => field, "op" => op, "value" => value }
  end

  # Q29 follow-up: a threshold present in both sets is built only from the proposed rule,
  # even when a different base rule owned it. (Kills "base kept even when shipped".)
  def test_shared_threshold_owned_by_another_base_rule_is_probed_only_from_proposed
    base = config(["big_property", [cond("line_of_business", "eq", "property"), cond("estimated_loss", "gte", 50_000)]])
    proposed = config(["big_property", [cond("line_of_business", "eq", "property")]],
                      ["big_auto", [cond("line_of_business", "eq", "auto"), cond("estimated_loss", "gte", 50_000)]])
    probes = Dispatch::Gate::BoundaryProbes.new(base, proposed).probes.select { |p| p.field == "estimated_loss" }
    assert_equal [49_999, 50_000, 50_001], probes.map(&:value)
    assert_equal [["big_auto", :proposed]], probes.map { |p| [p.rule_id, p.source] }.uniq
    assert(probes.all? { |p| p.claim.line_of_business == "auto" })
  end

  # Q55 G1: the other conditions are satisfied with whole dollars, so a fractional gte/lte
  # on another field still lets the probe reach its rule. (Kills "gte uses floor".)
  def test_fractional_other_conditions_are_satisfied_with_whole_dollars
    rules = config(["lux", [cond("vehicle_value", "gte", 60_000.5), cond("vehicle_value", "lte", 90_000.5),
                            cond("estimated_loss", "gte", 50_000)]])
    probes = Dispatch::Gate::BoundaryProbes.new(rules, rules).probes.select { |p| p.field == "estimated_loss" }
    refute_empty probes
    probes.each do |probe|
      assert_kind_of Integer, probe.claim.vehicle_value
      assert_operator probe.claim.vehicle_value, :>=, 60_001
      assert_operator probe.claim.vehicle_value, :<=, 90_000
    end
    at_threshold = probes.find { |p| p.value == 50_000 }
    assert_equal "lux", rules.match(at_threshold.claim)&.id
  end

  def test_fractional_gte_alone_reaches_its_rule
    rules = config(["lux", [cond("vehicle_value", "gte", 60_000.5), cond("estimated_loss", "gte", 50_000)]])
    probe = Dispatch::Gate::BoundaryProbes.new(rules, rules).probes.find { |p| p.field == "estimated_loss" && p.value == 50_000 }
    assert_equal 60_001, probe.claim.vehicle_value
    assert_equal "lux", rules.match(probe.claim)&.id
  end
end
