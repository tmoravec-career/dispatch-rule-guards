require_relative "../test_helper"
require "open3"
require "rbconfig"
require "stringio"
require "dispatch/gate/cli"

# Acceptance checks for the shipped data and the two named commands (Q53, Q54).
class ShippedDataTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GENERATOR_STATES = Dispatch::ScenarioGenerator::STATES.keys.freeze

  def root(path)
    File.join(ROOT, path)
  end

  def feature_roster
    GateBackground.roster
  end

  def shipped_roster
    JSON.parse(File.read(root("config/adjusters.json")))["adjusters"]
  end

  # --- Q53: the example files can't drift from the spec ------------------------

  def test_replay_claims_match_the_gate_background
    expected = GateBackground.replay_claims
    assert_equal 10, expected.size
    assert_equal expected, JSON.parse(File.read(root("examples/replay_claims.json")))
  end

  def test_demo_adjusters_match_the_gate_background
    assert_equal 8, feature_roster.size
    assert_equal({ "adjusters" => feature_roster }, JSON.parse(File.read(root("examples/demo_adjusters.json"))))
  end

  # Command 1, exactly as written in examples/README.md, from the repo root.
  def test_demo_command_reproduces_the_brief
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/rule_diff",
                                      "--base", "config/dispatch_rules.json",
                                      "--proposed", "examples/dispatch_rules.proposed.json",
                                      "--claims", "examples/replay_claims.json",
                                      "--adjusters", "examples/demo_adjusters.json", chdir: ROOT, binmode: true)
    assert_equal 1, status.exitstatus, err
    breaches = out[/^## Policy breaches\n(.*?)^## /m, 1].scan(/^\| `(\w+)` \| ([\d.]+) \| ([\d.]+) \|$/)
    assert_equal [%w[max_new_unassigned 0 2], %w[max_reroute_pct 10 50.0], %w[max_probe_changes 0 4]], breaches
    newly = out[/^## Newly unassigned\n(.*?)^## /m, 1].scan(/^\| (CLM-\d+) \| `(\w+)` \| `(\w+)` \|/)
    assert_equal [%w[CLM-2003 luxury_auto qualified_adjusters_at_capacity],
                  %w[CLM-2004 luxury_auto qualified_adjusters_at_capacity]], newly
  end

  # --- Q54: the shipped roster ---------------------------------------------------

  def test_shipped_roster_invariants
    roster = shipped_roster
    assert_equal 25, roster.size
    assert_equal roster.size, roster.map { |a| a["id"] }.uniq.size
    assert_equal feature_roster, roster.first(8), "ADJ-001..008 must equal the Background table"
    assert_equal 24, roster.count { |a| a["active"] }
    assert(roster.none? { |a| a["open_claims"] > a["capacity"] })
    Dispatch::Roster.from_h({ "adjusters" => roster })

    active = roster.select { |a| a["active"] }
    luxury_outside = active.select { |a| a["skills"].include?("luxury_vehicle") && !(a["licensed_states"] - %w[TX FL]).empty? }
    assert_equal [["ADJ-004", 2]], luxury_outside.map { |a| [a["id"], a["capacity"]] }

    has = ->(state, *skills) { active.any? { |a| a["licensed_states"].include?(state) && (skills - a["skills"]).empty? } }
    GENERATOR_STATES.each do |state|
      assert has.call(state, "auto", "large_loss"), "#{state}: no active auto + large_loss adjuster"
      assert has.call(state, "property"), "#{state}: no active property adjuster"
    end
    %w[TX FL LA].each do |state|
      assert has.call(state, "cat", "large_loss"), "#{state}: no active cat + large_loss adjuster"
      assert has.call(state, "property", "cat"), "#{state}: no active property + cat adjuster"
    end
  end

  def test_seeded_day_assigns_at_least_90_percent_under_base_rules
    engine = Dispatch::Engine.new(Dispatch::RulesConfig.load_file(root("config/dispatch_rules.json")))
    roster = Dispatch::Roster.load_file(root("config/adjusters.json"))
    results = Dispatch::ScenarioGenerator.new(seed: 42, count: 200).claims.map { |c| engine.dispatch(c, roster) }
    assigned = results.count(&:assigned?)
    unassigned = results.reject(&:assigned?).group_by(&:reason_code)
                        .map { |code, rs| "#{code}: #{rs.map { |r| "#{r.claim_number} (#{r.queue})" }.join(', ')}" }
    assert_operator assigned, :>=, 180, "#{assigned}/200 assigned. Unassigned by reason:\n#{unassigned.join("\n")}"
  end

  # Command 2, the realistic day: the bare seeded command still catches the demo edit.
  def test_realistic_day_detects_the_demo_edit
    Dir.mktmpdir do |dir|
      json = File.join(dir, "report.json")
      status = Dir.chdir(ROOT) do
        Dispatch::Gate::CLI.run(["--base", "config/dispatch_rules.json", "--proposed", "examples/dispatch_rules.proposed.json",
                                 "--json-out", json, "--markdown-out", File.join(dir, "report.md")],
                                stdout: StringIO.new, stderr: StringIO.new)
      end
      report = JSON.parse(File.read(json))
      assert_equal 1, status
      assert_operator report["newly_unassigned"].size, :>=, 1
      assert_includes report["policy_breaches"].map { |b| b["policy"] }, "max_new_unassigned"
      assert_equal [200, 42], report["summary"].values_at("replayed_claims", "seed")
      assert_readme_matches(report)
    end
  end

  # examples/README.md quotes the realistic day's numbers; keep them true to a fresh run.
  def assert_readme_matches(report)
    section = File.read(root("examples/README.md"))[/^## Realistic day.*?(?=^## |\z)/m]
    refute_nil section, "examples/README.md has no Realistic day section"
    report["policy_breaches"].each do |b|
      assert_includes section, "| `#{b['policy']}` | #{b['threshold']} | #{b['actual']} |"
    end
    assert_equal report["policy_breaches"].size, section.scan(/^\| `max_\w+` \|/).size, "README lists extra breaches"
    summary = report["summary"]
    assert_includes section, "#{report['rerouted'].size} claims (#{summary['reroute_pct']}%)"
    assert_includes section, "#{summary['unassigned_base']} under base, #{summary['unassigned_proposed']} under proposed"
    newly = section[/^- \*\*Newly unassigned:\*\*.*$/]
    assert_equal report["newly_unassigned"].map { |c| c["claim_number"] }.sort, newly.scan(/SIM-\d+/).sort
    reasons = report["newly_unassigned"].map { |c| "`#{c['reason_code']}`" }.uniq
    reasons.each { |r| assert_includes newly, r }
  end
end
