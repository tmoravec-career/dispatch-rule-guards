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

  def loss_probes(base, proposed)
    Dispatch::Gate::BoundaryProbes.new(base, proposed).probes.select { |p| p.field == "estimated_loss" }
  end

  def owners(probes)
    probes.map { |p| [p.rule_id, p.source, p.value] }.sort_by { |id, source, value| [id, source.to_s, value] }
  end

  AUTO_LARGE = ["auto_large", [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                               { "field" => "estimated_loss", "op" => "gte", "value" => 100_000 }]].freeze
  PROP_LARGE = ["prop_large", [{ "field" => "line_of_business", "op" => "eq", "value" => "property" },
                               { "field" => "estimated_loss", "op" => "gte", "value" => 100_000 }]].freeze

  # Q56 M1 (supersedes the old Q29 follow-up test): big_property no longer has its
  # threshold in the proposed rules, so it is probed from its base rule, even though
  # big_auto ships the same (field, value). big_auto is probed from the proposed rule.
  def test_shared_value_owned_by_another_base_rule_is_probed_from_both_owners
    base = config(["big_property", [cond("line_of_business", "eq", "property"), cond("estimated_loss", "gte", 50_000)]])
    proposed = config(["big_property", [cond("line_of_business", "eq", "property")]],
                      ["big_auto", [cond("line_of_business", "eq", "auto"), cond("estimated_loss", "gte", 50_000)]])
    probes = loss_probes(base, proposed)
    assert_equal [["big_auto", :proposed, 49_999], ["big_auto", :proposed, 50_000], ["big_auto", :proposed, 50_001],
                  ["big_property", :base, 49_999], ["big_property", :base, 50_000], ["big_property", :base, 50_001]],
                 owners(probes)
    probes.each do |p|
      assert_equal(p.rule_id == "big_auto" ? "auto" : "property", p.claim.line_of_business, p.to_h.inspect)
    end
  end

  # Q56 (a): deleting auto_large while prop_large keeps the same number must not hide the
  # auto boundary. Auto claims at $100,000 and $100,001 lose their route.
  def test_deleted_rule_sharing_a_value_is_still_probed_from_base
    probes = loss_probes(config(AUTO_LARGE, PROP_LARGE), config(PROP_LARGE))
    auto = probes.select { |p| p.rule_id == "auto_large" }
    assert_equal [99_999, 100_000, 100_001], auto.map(&:value)
    assert(auto.all? { |p| p.source == :base && p.claim.line_of_business == "auto" })
  end

  def test_deleted_rule_sharing_a_value_fails_the_gate_through_the_cli
    require "stringio"
    require "dispatch/gate/cli"
    Dir.mktmpdir do |dir|
      write = ->(name, data) { File.join(dir, name).tap { |path| File.write(path, JSON.generate(data)) } }
      to_h = ->(*rules) { config(*rules).to_h }
      base = write.("base.json", to_h.(AUTO_LARGE, PROP_LARGE))
      proposed = write.("proposed.json", to_h.(PROP_LARGE))
      claims = write.("claims.json", [{ "claim_number" => "A", "line_of_business" => "liability", "estimated_loss" => 1,
                                        "loss_state" => "TX" }])
      json = File.join(dir, "report.json")
      status = Dispatch::Gate::CLI.run(["--base", base, "--proposed", proposed, "--claims", claims, "--json-out", json,
                                        "--markdown-out", File.join(dir, "report.md")], stdout: StringIO.new, stderr: StringIO.new)
      report = JSON.parse(File.read(json))
      changed = report["boundary_probe_changes"].map { |p| [p["threshold_rule"], p["value"], p["base_queue"], p["proposed_queue"]] }
      assert_equal [["auto_large", 100_000, "auto_large", "general_intake"],
                    ["auto_large", 100_001, "auto_large", "general_intake"]], changed.sort
      assert_equal [{ "policy" => "max_probe_changes", "threshold" => 0, "actual" => 2 }], report["policy_breaches"]
      assert_equal 1, status
    end
  end

  # Q56 (b): a rule that keeps its (field, op, value) is probed from the proposed rule only;
  # another rule sharing the value doesn't create a duplicate base probe.
  def test_rule_keeping_its_threshold_gets_no_duplicate_base_probe
    rules = config(AUTO_LARGE, PROP_LARGE)
    assert_equal [["auto_large", :proposed, 99_999], ["auto_large", :proposed, 100_000], ["auto_large", :proposed, 100_001],
                  ["prop_large", :proposed, 99_999], ["prop_large", :proposed, 100_000], ["prop_large", :proposed, 100_001]],
                 owners(loss_probes(rules, config(AUTO_LARGE, PROP_LARGE)))
  end

  # Q56 (c): auto_large keeps existing but drops only its threshold condition, while
  # prop_large keeps the same number. The old auto boundary is probed from the base rule.
  def test_rule_dropping_only_its_threshold_is_probed_from_base
    auto_any = ["auto_large", [cond("line_of_business", "eq", "auto")]]
    probes = loss_probes(config(AUTO_LARGE, PROP_LARGE), config(auto_any, PROP_LARGE))
    auto = probes.select { |p| p.rule_id == "auto_large" }
    assert_equal [[:base, 99_999], [:base, 100_000], [:base, 100_001]], auto.map { |p| [p.source, p.value] }
    assert(auto.all? { |p| p.claim.line_of_business == "auto" })
    # $99,999 auto: general_intake under base, auto_large under proposed. That change must be visible.
    probe = auto.find { |p| p.value == 99_999 }
    assert_nil config(AUTO_LARGE, PROP_LARGE).match(probe.claim)
    assert_equal "auto_large", config(auto_any, PROP_LARGE).match(probe.claim).id
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
