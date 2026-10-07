require_relative "../test_helper"

# Replay, diff and policy evaluation (Q25-Q33), checked against the rule_change_gate scenarios.
class ImpactTest < Minitest::Test
  include DispatchFixtures

  def run_gate(proposed_hash, claims: REPLAY_CLAIMS, policy: {}, seed: nil, base_hash: base_rules_hash)
    Dispatch::Gate::Impact.new(
      base: Dispatch::RulesConfig.from_h(base_hash),
      proposed: Dispatch::RulesConfig.from_h(proposed_hash),
      claims: claims, roster: roster,
      policy: Dispatch::Gate::Policy.new(**policy), seed: seed
    ).report
  end

  def breaches(report)
    report["policy_breaches"].map { |b| [b["policy"], b["threshold"], b["actual"]] }
  end

  def probe_changes(report)
    report["boundary_probe_changes"].map { |p| [p["field"], p["value"]] }
  end

  def test_demo_breaches_all_three_policies
    report = run_gate(demo_proposed_hash)
    assert_equal [["max_new_unassigned", 0, 2], ["max_reroute_pct", 10, 50.0], ["max_probe_changes", 0, 4]], breaches(report)
    assert_equal [["CLM-2003", "luxury_auto", "qualified_adjusters_at_capacity"],
                  ["CLM-2004", "luxury_auto", "qualified_adjusters_at_capacity"]],
                 report["newly_unassigned"].map { |c| c.values_at("claim_number", "queue", "reason_code") }
    assert_equal [["auto_standard", 5, 1], ["cat_large_loss", 2, 1], ["coastal_property", 0, 1], ["luxury_auto", 1, 5]],
                 report["queue_changes"].map { |q| q.values_at("queue", "base", "proposed") }
    assert_equal [["CLM-2001", "auto_standard", "luxury_auto"], ["CLM-2002", "auto_standard", "luxury_auto"],
                  ["CLM-2003", "auto_standard", "luxury_auto"], ["CLM-2005", "auto_standard", "luxury_auto"],
                  ["CLM-2006", "cat_large_loss", "coastal_property"]],
                 report["rerouted"].map { |c| c.values_at("claim_number", "base_queue", "proposed_queue") }
    assert_equal({ "replayed_claims" => 10, "seed" => nil, "reroute_pct" => 50.0,
                   "unassigned_base" => 0, "unassigned_proposed" => 2 }, report["summary"])
    assert_equal [["estimated_loss", 50_000], ["vehicle_value", 60_000], ["vehicle_value", 60_001], ["vehicle_value", 99_999]],
                 probe_changes(report)
    change = report["boundary_probe_changes"].first
    assert_equal ["cat_large_loss", "cat_large_loss", "general_intake", nil],
                 change.values_at("base_queue", "base_matched_rule", "proposed_queue", "proposed_matched_rule")
    assert Dispatch::Gate::Impact.breached?(report)
  end

  def test_report_has_the_specified_top_level_keys
    assert_equal %w[summary policy_breaches newly_unassigned newly_assigned queue_changes rerouted
                    boundary_probes boundary_probe_changes], run_gate(base_rules_hash).keys
  end

  def test_no_change_passes_with_empty_report
    report = run_gate(base_rules_hash)
    assert_empty report["policy_breaches"]
    %w[newly_unassigned newly_assigned rerouted queue_changes boundary_probe_changes].each { |k| assert_empty report[k], k }
    assert_equal 0.0, report["summary"]["reroute_pct"]
    assert_equal 12, report["boundary_probes"].size
    refute Dispatch::Gate::Impact.breached?(report)
  end

  def test_off_by_one_alone_fails_only_on_probes
    proposed = with_condition(base_rules_hash, "cat_large_loss", "estimated_loss", "gt", 50_000)
    report = run_gate(proposed)
    assert_equal [["max_probe_changes", 0, 1]], breaches(report)
    assert_empty report["newly_unassigned"]
    assert_equal 10.0, report["summary"]["reroute_pct"]
    assert_empty breaches(run_gate(proposed, policy: { max_probe_changes: 1 }))
  end

  def test_exactly_ten_percent_is_within_policy
    proposed = with_condition(base_rules_hash, "auto_fast_track", "estimated_loss", "lt", 3_000)
    report = run_gate(proposed, policy: { max_probe_changes: 3 })
    assert_empty breaches(report)
    assert_equal [["CLM-2008", "auto_fast_track", "auto_standard"]],
                 report["rerouted"].map { |c| c.values_at("claim_number", "base_queue", "proposed_queue") }
    assert_equal [["estimated_loss", 3_000], ["estimated_loss", 3_001], ["estimated_loss", 4_999]], probe_changes(report)
  end

  def test_more_than_ten_percent_fails
    proposed = with_condition(base_rules_hash, "auto_fast_track", "estimated_loss", "lt", 3_000)
    proposed = with_condition(proposed, "luxury_auto", "vehicle_value", "gte", 87_000)
    report = run_gate(proposed)
    assert_equal [["max_reroute_pct", 10, 20.0], ["max_probe_changes", 0, 6]], breaches(report)
    assert_empty report["newly_unassigned"]
  end

  def test_unassigned_under_both_is_not_new
    claims = [claim("CLM-2101", "auto", 12_000, 130_000, false, "GA"), claim("CLM-2102", "liability", 40_000, nil, false, "WY")]
    proposed = with_condition(base_rules_hash, "luxury_auto", "vehicle_value", "gte", 120_000)
    report = run_gate(proposed, claims: claims, policy: { max_probe_changes: 3 })
    assert_empty breaches(report)
    assert_empty report["newly_unassigned"]
    assert_equal [2, 2], report["summary"].values_at("unassigned_base", "unassigned_proposed")
  end

  LUXURY_OVERFLOW = [
    DispatchFixtures.claim("CLM-2201", "auto", 12_000, 105_000, false, "CA"),
    DispatchFixtures.claim("CLM-2202", "auto", 15_000, 130_000, false, "CA"),
    DispatchFixtures.claim("CLM-2203", "auto", 9_000, 140_000, false, "CA")
  ].freeze

  def test_newly_assigned_is_informational
    proposed = with_condition(base_rules_hash, "luxury_auto", "vehicle_value", "gte", 110_000)
    report = run_gate(proposed, claims: LUXURY_OVERFLOW, policy: { max_reroute_pct: "50", max_probe_changes: 3 })
    assert_empty breaches(report)
    assert_equal [["CLM-2203", "luxury_auto", "ADJ-004"]],
                 report["newly_assigned"].map { |c| c.values_at("claim_number", "queue", "adjuster") }
    assert_equal [["CLM-2201", "luxury_auto", "auto_standard"]],
                 report["rerouted"].map { |c| c.values_at("claim_number", "base_queue", "proposed_queue") }
    assert_equal [1, 0, 33.3], report["summary"].values_at("unassigned_base", "unassigned_proposed", "reroute_pct")
  end

  def test_reroute_policy_compares_unrounded_percentage
    proposed = with_condition(base_rules_hash, "luxury_auto", "vehicle_value", "gte", 110_000)
    # 33.33...% breaches 33.3; shown with 2 decimals so it doesn't read "33.3 > 33.3" (Q56).
    { "33.4" => [], "33.34" => [], "33.3" => [["max_reroute_pct", 33.3, 33.33]] }.each do |threshold, expected|
      report = run_gate(proposed, claims: LUXURY_OVERFLOW, policy: { max_reroute_pct: threshold, max_probe_changes: 3 })
      assert_equal expected, breaches(report), threshold
    end
  end

  def test_probe_only_change
    proposed = deep_copy(base_rules_hash)
    proposed["rules"] << { "id" => "high_value_property", "priority" => 55, "queue" => "high_value_property",
                           "required_skills" => %w[property large_loss],
                           "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "property" },
                                            { "field" => "estimated_loss", "op" => "gte", "value" => 75_000 }] }
    report = run_gate(proposed)
    assert_equal [["max_probe_changes", 0, 2]], breaches(report)
    assert_equal [["estimated_loss", 75_000], ["estimated_loss", 75_001]], probe_changes(report)
    assert_equal %w[coastal_property high_value_property],
                 report["boundary_probe_changes"].first.values_at("base_queue", "proposed_queue")
    assert_empty report["rerouted"]
  end

  def test_removed_rule_threshold_still_probed
    proposed = deep_copy(base_rules_hash)
    proposed["rules"].reject! { |r| r["id"] == "auto_fast_track" }
    report = run_gate(proposed)
    change = report["boundary_probe_changes"].find { |p| p["value"] == 4_999 }
    assert_equal %w[auto_fast_track auto_standard], change.values_at("base_queue", "proposed_queue")
  end

  def test_policy_flags
    {
      { max_new_unassigned: 2, max_reroute_pct: "50", max_probe_changes: 4 } => false,
      { max_new_unassigned: 1, max_reroute_pct: "50", max_probe_changes: 4 } => true,
      { max_new_unassigned: 2, max_reroute_pct: "49.9", max_probe_changes: 4 } => true,
      { max_new_unassigned: 2, max_reroute_pct: "50", max_probe_changes: 3 } => true,
      { max_new_unassigned: 2, max_reroute_pct: "50" } => true,
      { max_new_unassigned: 2, max_probe_changes: 4 } => true
    }.each do |policy, breached|
      assert_equal breached, Dispatch::Gate::Impact.breached?(run_gate(demo_proposed_hash, policy: policy)), policy.inspect
    end
  end

  def test_seeded_replay_is_reproducible_and_reports_the_seed
    claims = Dispatch::ScenarioGenerator.new(seed: 42, count: 200).claims
    proposed = with_condition(base_rules_hash, "luxury_auto", "vehicle_value", "gte", 60_000)
    first = run_gate(proposed, claims: claims, seed: 42)
    second = run_gate(proposed, claims: Dispatch::ScenarioGenerator.new(seed: 42, count: 200).claims, seed: 42)
    assert_equal JSON.generate(first), JSON.generate(second)
    assert_equal [200, 42], first["summary"].values_at("replayed_claims", "seed")
  end

  def test_zero_claims_is_zero_percent
    assert_equal 0.0, run_gate(demo_proposed_hash, claims: [])["summary"]["reroute_pct"]
  end

  # Q56: a rounded breach actual that equals the threshold is shown with 2 decimals.
  def test_breach_actual_never_displays_equal_to_its_threshold
    policy = Dispatch::Gate::Policy.new(max_reroute_pct: "10")
    actual = ->(pct) { policy.breaches(new_unassigned: 0, reroute_pct: pct, probe_changes: 0).first["actual"] }
    assert_equal 10.04, actual.call(Rational(1004, 100))
    assert_equal 10.01, actual.call(Rational(10_009, 1000))
    assert_equal 10.4, actual.call(Rational(104, 10))
    assert_equal 50.0, actual.call(Rational(50))
    assert_equal 10.0, Dispatch::Gate::Policy.display_pct(Rational(1004, 100)), "the summary keeps 1 decimal"
  end

  def test_policy_rejects_negative_or_non_numeric_thresholds
    assert_raises(ArgumentError) { Dispatch::Gate::Policy.new(max_new_unassigned: -1) }
    assert_raises(ArgumentError) { Dispatch::Gate::Policy.new(max_probe_changes: 1.5) }
    assert_raises(ArgumentError) { Dispatch::Gate::Policy.new(max_reroute_pct: "ten") }
    assert_raises(ArgumentError) { Dispatch::Gate::Policy.new(max_reroute_pct: "-1") }
  end
end
