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

  # Q56: cells escape "|" and collapse newlines, so a value can't break the table.
  def test_table_cells_are_escaped
    rules = base_rules_hash
    rules["rules"][1]["queue"] = "luxury|auto\nnext"
    md = Dispatch::Gate::MarkdownReport.render(
      Dispatch::Gate::Impact.new(base: base_config, proposed: Dispatch::RulesConfig.from_h(rules),
                                 claims: REPLAY_CLAIMS, roster: roster, policy: Dispatch::Gate::Policy.new).report
    )
    assert_includes md, "`luxury\\|auto next`"
    refute_includes md, "luxury|auto"
    refute_includes md, "auto\nnext"
    # Every row of the rerouted table still has exactly 3 cells (4 unescaped pipes).
    rerouted = md[/^## Rerouted claims\n\n(.*?)\n\n/m, 1].lines
    assert(rerouted.all? { |l| l.scan(/(?<!\\)\|/).size == 4 }, rerouted.inspect)
    assert_equal "a\\|b c", Dispatch::Gate::MarkdownReport.cell("a|b\r\n  c")
  end

  def test_json_report_is_stable_text
    a = Dispatch::Gate::Impact.to_json(report(demo_proposed_hash))
    b = Dispatch::Gate::Impact.to_json(report(demo_proposed_hash))
    assert_equal a, b
    assert a.end_with?("\n")
    assert_equal report(demo_proposed_hash), JSON.parse(a)
  end
end
