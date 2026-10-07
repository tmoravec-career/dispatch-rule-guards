require_relative "../test_helper"
require "stringio"
require "dispatch/gate/cli"

# Regression tests for defects found in the phase 2 QA pass. They FAIL until the
# defects are fixed; see the QA report for steps / expected / actual.
class QaDefectsTest < Minitest::Test
  include DispatchFixtures

  def setup
    @dir = Dir.mktmpdir
    write("base.json", JSON.generate(base_rules_hash))
    write("one_claim.json", '[{"claim_number":"A","line_of_business":"liability","estimated_loss":1,"loss_state":"TX"}]')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write(name, text)
    File.binwrite(File.join(@dir, name), text)
  end

  def path(name)
    File.join(@dir, name)
  end

  def gate(*args)
    out = StringIO.new
    err = StringIO.new
    [Dispatch::Gate::CLI.run(args, stdout: out, stderr: err), out.string, err.string]
  end

  # Q9/Q28: an invalid config exits 2. A non-UTF-8 byte (e.g. a Windows-1252 "é" in a
  # rule id) currently raises Encoding::CompatibilityError out of the CLI (exit 1 from bin/).
  def test_non_utf8_rules_file_is_an_input_error
    write("latin1.json", '{"rules":[{"id":"caf' + "\xE9".b + '","priority":1,"queue":"q","required_skills":[],"conditions":[]}]}')
    status, _out, err = gate("--base", path("base.json"), "--proposed", path("latin1.json"))
    assert_equal 2, status
    assert_match(/latin1\.json/, err)
  end

  # Q8: thresholds must be JSON numbers. 1e400 overflows to Float::INFINITY; it is
  # currently accepted, then the boundary probes raise FloatDomainError (exit 1).
  def test_threshold_that_overflows_to_infinity_is_rejected
    write("inf.json", '{"rules":[{"id":"big","priority":1,"queue":"big","required_skills":[],' \
                      '"conditions":[{"field":"estimated_loss","op":"gte","value":1e400}]}]}')
    error = assert_raises(Dispatch::ConfigError) { Dispatch::RulesConfig.load_file(path("inf.json")) }
    assert_equal ["rules[0].conditions[0].value"], error.errors.map(&:path)
    status, = gate("--base", path("base.json"), "--proposed", path("inf.json"))
    assert_equal 2, status
  end

  # Q29: every threshold is probed at value-1, value and value+1 from its owning rule.
  # When two thresholds on the same field are 1 apart, the probe points collide and the
  # second rule's probes are dropped, so a gte->gt off-by-one on it passes the gate.
  def test_off_by_one_on_an_adjacent_threshold_is_caught_by_probes
    rules = lambda do |op|
      JSON.generate("rules" => [
        { "id" => "big_property", "priority" => 10, "queue" => "big_property", "required_skills" => [],
          "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "property" },
                           { "field" => "estimated_loss", "op" => "gte", "value" => 50_000 }] },
        { "id" => "big_auto", "priority" => 20, "queue" => "big_auto", "required_skills" => [],
          "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                           { "field" => "estimated_loss", "op" => op, "value" => 50_001 }] }
      ])
    end
    write("adj_base.json", rules.call("gte"))
    write("adj_proposed.json", rules.call("gt"))
    status, = gate("--base", path("adj_base.json"), "--proposed", path("adj_proposed.json"),
                   "--claims", path("one_claim.json"), "--json-out", path("out.json"), "--markdown-out", path("out.md"))
    changes = JSON.parse(File.read(path("out.json")))["boundary_probe_changes"]
    assert(changes.any? { |p| p["value"] == 50_001 && p["threshold_rule"] == "big_auto" },
           "expected the auto claim at $50,001 (big_auto -> general_intake) to be a probe change, got #{changes.inspect}")
    assert_equal 1, status
  end
end
