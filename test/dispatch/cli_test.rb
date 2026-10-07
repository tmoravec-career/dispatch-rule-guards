require_relative "../test_helper"
require "stringio"
require "dispatch/gate/cli"

# bin/rule_diff flags, defaults and exit codes (Q28, Q32), run in-process.
class CLITest < Minitest::Test
  include DispatchFixtures

  ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir
    write("base.json", base_rules_hash)
    write("proposed.json", demo_proposed_hash)
    write("roster.json", { "adjusters" => deep_copy(ROSTER) })
    write("replay.json", REPLAY_CLAIMS.map(&:to_h))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write(name, data)
    File.write(path(name), data.is_a?(String) ? data : JSON.generate(data))
  end

  def path(name)
    File.join(@dir, name)
  end

  def gate(*args)
    out = StringIO.new
    err = StringIO.new
    status = Dispatch::Gate::CLI.run(args.flatten, stdout: out, stderr: err)
    [status, out.string, err.string]
  end

  def with_reports(*args)
    gate(*args, "--json-out", path("out/report.json"), "--markdown-out", path("out/report.md"))
  end

  def replay_args(proposed = "proposed.json")
    ["--base", path("base.json"), "--proposed", path(proposed), "--claims", path("replay.json"),
     "--adjusters", path("roster.json")]
  end

  def json_report
    JSON.parse(File.read(path("out/report.json")))
  end

  def test_demo_exits_1_with_all_three_breaches
    status, out, = with_reports(replay_args)
    assert_equal 1, status
    assert_equal %w[max_new_unassigned max_reroute_pct max_probe_changes], json_report["policy_breaches"].map { |b| b["policy"] }
    assert_includes out, "FAIL"
    assert_includes File.read(path("out/report.md")), "## Boundary probe changes"
  end

  def test_no_change_exits_0
    status, = with_reports(replay_args("base.json"))
    assert_equal 0, status
    assert_empty json_report["policy_breaches"]
  end

  def test_policy_flags
    status, = with_reports(replay_args, %w[--max-new-unassigned 2 --max-reroute-pct 50 --max-probe-changes 4])
    assert_equal 0, status
    status, = with_reports(replay_args, %w[--max-new-unassigned 2 --max-reroute-pct 49.9 --max-probe-changes 4])
    assert_equal 1, status
  end

  def test_markdown_goes_to_stdout_without_markdown_out
    status, out, = gate(replay_args)
    assert_equal 1, status
    assert_includes out, "## Summary"
    assert_includes out, "max_probe_changes"
  end

  def test_seeded_default_claims_and_default_roster
    status, = with_reports("--base", path("base.json"), "--proposed", path("base.json"))
    assert_equal 0, status
    assert_equal [200, 42], json_report["summary"].values_at("replayed_claims", "seed")
    with_reports("--base", path("base.json"), "--proposed", path("base.json"), "--seed", "7", "--claim-count", "5")
    assert_equal [5, 7], json_report["summary"].values_at("replayed_claims", "seed")
  end

  def test_runs_are_byte_identical
    with_reports("--base", path("base.json"), "--proposed", path("proposed.json"), "--seed", "42")
    first = File.binread(path("out/report.json"))
    with_reports("--base", path("base.json"), "--proposed", path("proposed.json"), "--seed", "42")
    assert_equal first, File.binread(path("out/report.json"))
    refute_includes first, @dir
  end

  def test_invalid_proposed_rules_exit_2_naming_file_and_code
    write("broken.json", '{"rules": [{"id": "x", "priority": 1, "queue": "q", "required_skills": [], ' \
                         '"conditions": [{"field": "vehicle_value", "op": "gtee", "value": 1}]}]}')
    status, _, err = with_reports(replay_args("broken.json"))
    assert_equal 2, status
    assert_includes err, "unknown_operator"
    assert_includes err, "broken.json"
    refute File.exist?(path("out/report.json"))
    refute File.exist?(path("out/report.md"))
  end

  def test_both_invalid_files_are_reported
    write("bad_base.json", '{"rules": [], "enforce_licensing": false}')
    write("bad_proposed.json", '{"rules": [{"id": "x"}]}')
    status, _, err = with_reports("--base", path("bad_base.json"), "--proposed", path("bad_proposed.json"))
    assert_equal 2, status
    assert_includes err, "bad_base.json"
    assert_includes err, "bad_proposed.json"
  end

  def test_invalid_claims_or_roster_exit_2
    write("bad_claims.json", '[{"claim_number": "C"}]')
    status, _, err = with_reports("--base", path("base.json"), "--proposed", path("base.json"), "--claims", path("bad_claims.json"))
    assert_equal 2, status
    assert_includes err, "missing_field"
    write("bad_roster.json", '{"adjusters": [{"id": "A"}]}')
    status, = with_reports("--base", path("base.json"), "--proposed", path("base.json"), "--adjusters", path("bad_roster.json"))
    assert_equal 2, status
  end

  USAGE_ERRORS = [
    %w[--base base.json],
    %w[--base base.json --proposed missing.json],
    %w[--base base.json --proposed base.json --max-reroute-pct ten],
    %w[--base base.json --proposed base.json --max-probe-changes -1],
    %w[--base base.json --proposed base.json --max-new-unassigned 1.5],
    %w[--base base.json --proposed base.json --seed abc],
    %w[--base base.json --proposed base.json --claim-count 0],
    %w[--base base.json --proposed base.json --claims replay.json --seed 1],
    %w[--base base.json --proposed base.json --bogus 1],
    %w[--base base.json --base base.json --proposed base.json],
    %w[--base base.json --proposed],
    %w[stray]
  ].freeze

  USAGE_ERRORS.each_with_index do |args, i|
    define_method("test_usage_error_#{i}") do
      resolved = args.map { |a| a.end_with?(".json") ? path(a) : a }
      status, _, err = with_reports(resolved)
      assert_equal 2, status, args.join(" ")
      refute_empty err
      refute File.exist?(path("out/report.json")), args.join(" ")
    end
  end

  def test_help_exits_0
    status, out, = gate("--help")
    assert_equal 0, status
    assert_includes out, "--max-probe-changes"
  end

  def test_shipped_configs_are_valid_and_the_example_reproduces_the_demo
    out = path("out/report.json")
    status, = gate("--base", File.join(ROOT, "config/dispatch_rules.json"),
                   "--proposed", File.join(ROOT, "examples/dispatch_rules.proposed.json"),
                   "--claims", File.join(ROOT, "examples/replay_claims.json"), "--json-out", out,
                   "--markdown-out", path("out/report.md"))
    assert_equal 1, status
    assert_equal [["max_new_unassigned", 0, 2], ["max_reroute_pct", 10, 50.0], ["max_probe_changes", 0, 4]],
                 JSON.parse(File.read(out))["policy_breaches"].map { |b| b.values_at("policy", "threshold", "actual") }
  end
end
