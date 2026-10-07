require_relative "../test_helper"
require "stringio"
require "open3"
require "rbconfig"

load File.expand_path("../../script/flake_report.rb", __dir__) unless defined?(FlakeReport)

# script/flake_report.rb: merges JUnit XML from repeated runs and labels each test stable,
# flaky or broken. Inputs mirror Cucumber's junit formatter (one testsuite per feature file,
# <failure> for a failed scenario, <skipped/> for a skipped one).
class FlakeReportTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir("flake_report")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # results: { "scenario name" => :pass | :fail | :skip }
  def write_run(run, results, feature: "Dispatch routing", file: "TEST-features-dispatch_routing.xml")
    dir = File.join(@dir, run)
    FileUtils.mkdir_p(dir)
    cases = results.map do |name, result|
      body = case result
             when :fail then %(<failure message="failed #{name}" type="failed"><![CDATA[expected 1, got 2\nbacktrace]]></failure>)
             when :skip then "<skipped/>"
             else ""
             end
      %(<testcase classname="#{feature}" name="#{name.gsub('"', '&quot;')}" time="0.01">#{body}</testcase>)
    end
    File.write(File.join(dir, file), <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <testsuite failures="0" errors="0" skipped="0" tests="#{results.size}" time="0.1" name="#{feature}">
      #{cases.join("\n")}
      </testsuite>
    XML
    dir
  end

  def report(*runs)
    out = StringIO.new
    err = StringIO.new
    json = File.join(@dir, "report.json")
    status = FlakeReport.main([*runs, "--json", json], out: out, err: err)
    [status, out.string, err.string, File.exist?(json) ? JSON.parse(File.read(json)) : nil]
  end

  def labels(json)
    json["tests"].to_h { |t| [t["name"], t["label"]] }
  end

  def test_labels_each_test_stable_flaky_or_broken_across_runs
    runs = [
      write_run("run-1", { "A" => :pass, "B" => :pass, "C" => :fail }),
      write_run("run-2", { "A" => :pass, "B" => :fail, "C" => :fail }),
      write_run("run-3", { "A" => :pass, "B" => :pass, "C" => :fail })
    ]
    status, markdown, _, json = report(*runs)

    assert_equal 1, status
    assert_equal({ "A" => "stable", "B" => "flaky", "C" => "broken" }, labels(json))
    assert_equal({ "stable" => 1, "flaky" => 1, "broken" => 1, "not_run" => 0 }, json["summary"])
    assert_equal %w[passed failed passed], json["tests"].find { |t| t["name"] == "B" }["outcomes"]
    assert_includes markdown, "## Flake report: FAIL"
    assert_includes markdown, "**1 stable**, **1 flaky**, **1 broken**"
    assert_includes markdown, "| Dispatch routing :: B | pass | FAIL | pass | failed B |"
    assert_includes markdown, "### Broken (1)"
  end

  def test_all_stable_exits_0
    runs = (1..3).map { |i| write_run("run-#{i}", { "A" => :pass, "B" => :pass }) }
    status, markdown, _, json = report(*runs)

    assert_equal 0, status
    assert_equal({ "A" => "stable", "B" => "stable" }, labels(json))
    assert_includes markdown, "## Flake report: PASS"
  end

  def test_skips_are_not_runs_and_an_always_skipped_test_gets_no_label
    runs = [
      write_run("run-1", { "A" => :skip, "B" => :skip }),
      write_run("run-2", { "A" => :pass, "B" => :skip }),
      write_run("run-3", { "A" => :pass, "B" => :skip })
    ]
    status, _, _, json = report(*runs)

    assert_equal 0, status
    assert_equal({ "A" => "stable", "B" => "not_run" }, labels(json))
  end

  def test_a_test_missing_from_a_run_is_labelled_from_the_runs_it_ran_in_and_reported
    runs = [
      write_run("run-1", { "A" => :pass, "B" => :fail }),
      write_run("run-2", { "A" => :pass }),
      write_run("run-3", { "A" => :pass, "B" => :pass })
    ]
    status, markdown, _, json = report(*runs)

    assert_equal 1, status
    assert_equal "flaky", labels(json)["B"]
    assert_equal %w[failed missing passed], json["tests"].find { |t| t["name"] == "B" }["outcomes"]
    assert_includes markdown, "Dispatch routing :: B: missing from run(s) 2"
  end

  def test_tests_are_keyed_by_feature_and_name_across_several_files_per_run
    runs = (1..2).map do |i|
      dir = write_run("run-#{i}", { "Same name" => :pass }, feature: "Dispatch routing")
      write_run("run-#{i}", { "Same name" => i == 1 ? :pass : :fail }, feature: "Web UI", file: "TEST-features-work_queue.xml")
      dir
    end
    _, _, _, json = report(*runs)

    assert_equal({ "Dispatch routing :: Same name" => "stable", "Web UI :: Same name" => "flaky" },
                 json["tests"].to_h { |t| [t["id"], t["label"]] })
  end

  # A run whose testcases are the attempts of one test, in order (e.g. Cucumber --retry).
  def write_attempts(run, attempts)
    dir = File.join(@dir, run)
    FileUtils.mkdir_p(dir)
    cases = attempts.map do |result|
      body = { fail: %(<failure message="boom"/>), skip: "<skipped/>", pass: "" }.fetch(result)
      %(<testcase classname="F" name="Row">#{body}</testcase>)
    end
    File.write(File.join(dir, "r.xml"), %(<testsuite name="F">#{cases.join}</testsuite>))
    dir
  end

  def test_a_failure_then_a_pass_in_one_run_is_one_flaky_test
    status, markdown, _, json = report(write_attempts("run-1", %i[fail pass]), write_attempts("run-2", %i[pass]))

    assert_equal 1, status
    assert_equal [["F :: Row", "flaky"]], json["tests"].map { |t| [t["id"], t["label"]] }
    assert_equal %w[flaky passed], json["tests"].first["outcomes"]
    assert_equal "boom", json["tests"].first["first_failure"]
    assert_includes markdown, "| F :: Row | FAIL+pass | pass | boom |"
  end

  def test_repeated_attempts_with_one_result_collapse_to_that_result
    _, _, _, json = report(write_attempts("run-1", %i[pass pass]), write_attempts("run-2", %i[skip pass]))
    assert_equal [["F :: Row", "stable"]], json["tests"].map { |t| [t["id"], t["label"]] }

    _, _, _, json = report(write_attempts("run-1", %i[fail fail]), write_attempts("run-2", %i[fail skip]))
    assert_equal [["F :: Row", "broken"]], json["tests"].map { |t| [t["id"], t["label"]] }
  end

  def test_accepts_a_single_xml_file_as_a_run_and_testsuites_roots
    file = File.join(@dir, "single.xml")
    File.write(file, '<testsuites><testsuite name="S"><testcase classname="S" name="T"><error message="E"/></testcase></testsuite></testsuites>')
    status, _, _, json = report(file)

    assert_equal 1, status
    assert_equal({ "T" => "broken" }, labels(json))
  end

  def test_usage_and_input_errors_exit_2
    status, _, err, = report
    assert_equal 2, status
    assert_includes err, "at least one run"

    empty = File.join(@dir, "empty")
    FileUtils.mkdir_p(empty)
    status, _, err, = report(empty)
    assert_equal 2, status
    assert_includes err, "no JUnit XML found"

    bad = File.join(@dir, "bad.xml")
    File.write(bad, "<testsuite><testcase")
    status, _, err, = report(bad)
    assert_equal 2, status
    assert_includes err, "malformed XML"
  end

  def test_runs_as_a_plain_ruby_script_and_writes_markdown
    runs = (1..2).map { |i| write_run("run-#{i}", { "A" => :pass }) }
    md = File.join(@dir, "flake.md")
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "script", "flake_report.rb"), "--markdown", md, *runs)

    assert_equal 0, status.exitstatus, err
    assert_includes out, "## Flake report: PASS"
    assert_equal out, File.binread(md)
  end
end
