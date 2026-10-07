require_relative "../test_helper"

# Markdown report for the PR comment (Q32).
class MarkdownReportTest < Minitest::Test
  include DispatchFixtures

  def report(proposed_hash)
    Dispatch::Gate::Impact.new(base: base_config, proposed: Dispatch::RulesConfig.from_h(proposed_hash),
                               claims: REPLAY_CLAIMS, roster: roster, policy: Dispatch::Gate::Policy.new).report
  end

  def test_sections_in_order
    md = Dispatch::Gate::MarkdownReport.render(report(demo_proposed_hash))
    assert_equal ["Summary", "Policy breaches", "Newly unassigned", "Queue changes", "Rerouted claims", "Boundary probe changes"],
                 md.scan(/^## (.+)$/).flatten
  end

  def test_demo_mentions_the_breaches_and_claims
    md = Dispatch::Gate::MarkdownReport.render(report(demo_proposed_hash))
    %w[CLM-2003 CLM-2004 50000 max_new_unassigned max_reroute_pct max_probe_changes FAIL].each do |text|
      assert_includes md, text
    end
  end

  def test_clean_report_says_pass_and_none
    md = Dispatch::Gate::MarkdownReport.render(report(base_rules_hash))
    assert_includes md, "PASS"
    assert_includes md, "None."
    refute_includes md, "FAIL"
  end

  def test_json_report_is_stable_text
    a = Dispatch::Gate::Impact.to_json(report(demo_proposed_hash))
    b = Dispatch::Gate::Impact.to_json(report(demo_proposed_hash))
    assert_equal a, b
    assert a.end_with?("\n")
    assert_equal report(demo_proposed_hash), JSON.parse(a)
  end
end
