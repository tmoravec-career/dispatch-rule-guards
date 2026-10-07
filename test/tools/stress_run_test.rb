require_relative "../test_helper"
require "open3"
require "socket"
require "rbconfig"

load File.expand_path("../../bin/stress_run", __dir__) unless defined?(StressRun)

# bin/stress_run (LOAD_TEST_CRITERIA.md "Stress", Q49): the report it builds from a k6 summary,
# and its exit codes when k6 can't produce a stress result. No k6 run here: the breach fixture
# is a real --summary-export from a local stress run with 500 ms of injected latency
# (k6 v2.2.0, scaled to 1-5 VUs), trimmed to the metrics the runner reads.
class StressRunTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FIXTURE = File.join(ROOT, "test", "fixtures", "k6", "stress_summary_breach.json")
  ABORT_LOG = "time=\"2026-10-07T02:37:36-05:00\" level=error msg=\"thresholds on metrics 'http_req_duration' " \
              "were crossed; at least one has abortOnFail enabled, stopping test prematurely\"\n".freeze

  def breach_summary
    JSON.parse(File.read(FIXTURE))
  end

  def test_a_breach_reports_the_last_step_reached_and_the_threshold_that_aborted
    report = StressRun.build_report(breach_summary, ABORT_LOG, 99)

    assert_equal 1, report["breaking_point_vus"]
    assert_equal 3, report["breaking_point_step"]
    assert_equal "http_req_duration", report["first_failed_threshold"]
    assert_equal({ "http_req_failed" => "passed", "http_req_duration" => "failed", "checks" => "passed" }, report["thresholds"])
    assert_equal [1, 2, 3, 4, 5, 6], report["steps"].map { |s| s["step"] }
    assert_equal [4, 2, 1, 0, 0, 0], report["steps"].map { |s| s["requests"] }
    assert_operator report["steps"].first["p95_ms"], :>, 500
    assert_nil report["steps"].last["p95_ms"], "a step never reached has no p95"
  end

  def test_without_the_abort_line_the_first_failed_gate_metric_is_reported
    report = StressRun.build_report(breach_summary, "", 99)
    assert_equal "http_req_duration", report["first_failed_threshold"]
  end

  def test_a_run_that_survived_every_step_has_no_breaking_point_but_keeps_the_keys
    summary = breach_summary
    summary["metrics"]["http_req_duration"]["thresholds"] = { "p(95)<300" => false }
    report = StressRun.build_report(summary, "", 0)

    assert report.key?("breaking_point_vus")
    assert report.key?("first_failed_threshold")
    assert_nil report["breaking_point_vus"]
    assert_nil report["first_failed_threshold"]
  end

  # BUG-032. stress_summary_all_401.json is the breach fixture with every request marked failed,
  # as a run with a wrong token (all 401s) exports it.
  def test_a_run_where_step_1_got_no_successful_response_is_a_misconfiguration
    summary = JSON.parse(File.read(File.join(ROOT, "test", "fixtures", "k6", "stress_summary_all_401.json")))
    problem = StressRun.misconfiguration(StressRun.build_report(summary, "", 99))

    refute_nil problem
    assert_includes problem, "100.0% of step 1's 4 requests failed"
    assert_includes problem, "K6_API_TOKEN"
  end

  def test_a_real_breach_is_not_a_misconfiguration
    assert_nil StressRun.misconfiguration(StressRun.build_report(breach_summary, ABORT_LOG, 99))
  end

  def test_a_run_whose_first_step_sent_nothing_is_a_misconfiguration
    summary = breach_summary
    summary["metrics"]["http_req_failed{step:step1_vus1}"].merge!("passes" => 0, "fails" => 0, "value" => 0)
    assert_includes StressRun.misconfiguration(StressRun.build_report(summary, "", 99)), "sent no requests"
  end

  def test_the_run_duration_comes_from_state_or_else_from_a_counter_rate
    assert_equal 1234, StressRun.test_run_duration_ms({ "state" => { "testRunDurationMs" => 1234 } })
    derived = StressRun.test_run_duration_ms({ "metrics" => { "http_reqs" => { "count" => 26, "rate" => 0.8651357311282195 } } })
    assert_in_delta 30_053, derived, 1
    assert_nil StressRun.test_run_duration_ms({ "metrics" => {} })
  end

  def test_an_explicit_k6_bin_is_used_or_nothing
    assert_nil StressRun.k6_binary({ "K6_BIN" => File.join(ROOT, "no-such-k6"), "PATH" => ENV.fetch("PATH", "") })
    assert_equal RbConfig.ruby, StressRun.k6_binary({ "K6_BIN" => RbConfig.ruby })
  end

  # --- exit 2: no stress result ---

  def run_stress(env)
    Open3.capture3(env, RbConfig.ruby, File.join(ROOT, "bin", "stress_run"),
                   "--report", File.join(@dir, "stress_report.json"), "--summary", File.join(@dir, "summary.json"), chdir: ROOT)
  end

  def setup
    @dir = Dir.mktmpdir("stress_run")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_exits_2_when_k6_is_missing
    _, err, status = run_stress("K6_BIN" => File.join(@dir, "k6-missing"))
    assert_equal 2, status.exitstatus
    assert_includes err, "k6 not found"
    refute File.exist?(File.join(@dir, "stress_report.json"))
  end

  def test_exits_2_when_the_app_is_unreachable
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    _, err, status = run_stress("K6_BIN" => RbConfig.ruby, "K6_BASE_URL" => "http://127.0.0.1:#{port}")
    assert_equal 2, status.exitstatus
    assert_includes err, "not reachable"
  end

  # A "k6" that exits with an error (here, ruby given k6's arguments) is not a stress result.
  def test_exits_2_when_k6_does_not_complete
    with_up_endpoint do |base_url|
      _, err, status = run_stress("K6_BIN" => RbConfig.ruby, "K6_BASE_URL" => base_url)
      assert_equal 2, status.exitstatus
      assert_includes err, "k6 did not complete"
      refute File.exist?(File.join(@dir, "stress_report.json"))
    end
  end

  # A minimal HTTP server answering 200 to one request, for the runner's /up check.
  def with_up_endpoint
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.readpartial(4096)
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      client.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread&.join(5)
    server&.close
  end
end
