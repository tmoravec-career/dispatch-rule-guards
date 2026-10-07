require "json"
require "net/http"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "fileutils"

# The @k6_pr / @k6_nightly harness (STEP_GLOSSARY.md section 9, LOAD_TEST_CRITERIA.md).
#
# "the app is running with the seed roster and rules" resets the (file-based) test database to
# the shipped roster, then a real Puma server is booted as a subprocess on a free port, in the
# test environment, on that same database, so the scenario can check k6's claims and run the
# capacity audit against what the server wrote. The server boots lazily, on the first k6 or
# stress run, so a latency setting given after the "running" step applies from the start.
# With K6_BASE_URL set, scenarios target that app instead and boot nothing.
#
# Waiting is event-driven: the boot waits for Puma's "Listening on" line on the server's
# output (IO.select with a deadline), and shutdown waits on the process with a deadline.
# k6 output and summaries go to reports/k6/ (uploaded by CI), every file keyed by the run
# (BUG-029): <profile>-L<scenario line>-<scenario slug>[-latency<N>ms], so the nightly
# scenarios that run the same profile twice never overwrite each other's evidence.
# K6_APP_LATENCY_MS (harness only) injects latency into the booted app when no step does,
# e.g. to force a k6 failure locally.
module K6World
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "load", "k6", "dispatch.js")
  REPORT_DIR = File.join(ROOT, "reports", "k6")
  BOOT_TIMEOUT = Integer(ENV.fetch("K6_APP_BOOT_TIMEOUT", "120"), 10)

  load File.join(ROOT, "bin", "stress_run") unless defined?(::StressRun)

  K6Run = Struct.new(:profile, :status, :output, :summary_path) do
    def summary
      @summary ||= JSON.parse(File.read(summary_path))
    rescue Errno::ENOENT
      raise "k6 wrote no summary at #{summary_path} (exit #{status}):\n#{output}"
    end
  end

  StressRunResult = Struct.new(:status, :output, :report_path) do
    def report
      @report ||= JSON.parse(File.read(report_path))
    rescue Errno::ENOENT
      raise "bin/stress_run wrote no report at #{report_path} (exit #{status}):\n#{output}"
    end
  end

  # --- The app under load ---

  def use_seed_roster_and_rules!
    DispatchEvent.delete_all
    Claim.delete_all
    roster = DispatchSettings.roster
    Adjuster.where.not(id: roster.adjusters.map(&:id)).delete_all
    Adjuster.load_roster!(roster, reset_open_claims: true)
    @k6_app_wanted = true
  end

  def k6_scenario=(scenario)
    line = scenario.location.to_s[/:(\d+)/, 1]
    slug = scenario.name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 48].sub(/-\z/, "")
    @k6_scenario_key = ["L#{line}", slug].reject(&:empty?).join("-")
  end

  def k6_app_latency_ms
    @k6_app_latency_ms || ENV["K6_APP_LATENCY_MS"].presence&.then { |v| Integer(v, 10) }
  end

  # The file key for this scenario's run of `profile`.
  def k6_artifact_key(profile)
    latency = k6_app_latency_ms
    [profile, @k6_scenario_key, (latency && !external_app? ? "latency#{latency}ms" : nil)].compact.join("-")
  end

  def k6_app_latency_ms=(ms)
    flunk("the app is not booted by this suite when K6_BASE_URL is set; latency can't be injected") if external_app?
    @k6_app_latency_ms = ms
  end

  def external_app?
    !ENV["K6_BASE_URL"].to_s.empty?
  end

  def k6_api_token
    external_app? ? ENV.fetch("K6_API_TOKEN") { flunk("K6_BASE_URL is set but K6_API_TOKEN is not") } : (@k6_token ||= "k6-#{SecureRandom.hex(12)}")
  end

  def k6_base_url
    return ENV["K6_BASE_URL"].chomp("/") if external_app?

    ensure_k6_app!
    "http://127.0.0.1:#{@k6_app_port}"
  end

  def ensure_k6_app!
    flunk("no 'the app is running with the seed roster and rules' step before the k6 run") unless @k6_app_wanted
    return if @k6_app_pid

    @k6_app_port = free_port
    env = { "RAILS_ENV" => "test", "DISPATCH_API_TOKENS" => "#{k6_api_token}:ops", "PORT" => @k6_app_port.to_s,
            "DISPATCH_TEST_LATENCY_MS" => k6_app_latency_ms&.to_s }
    FileUtils.mkdir_p([REPORT_DIR, File.join(ROOT, "tmp", "pids")])
    reader, writer = IO.pipe
    @k6_app_pid = Process.spawn(env, RbConfig.ruby, File.join(ROOT, "bin", "rails"), "server", "-e", "test",
                                "-b", "127.0.0.1", "-p", @k6_app_port.to_s,
                                "-P", File.join(ROOT, "tmp", "pids", "k6-server-#{@k6_app_port}.pid"),
                                chdir: ROOT, out: writer, err: writer)
    writer.close
    @k6_app_waiter = Process.detach(@k6_app_pid)
    boot_log = wait_for_listening(reader)
    drain_server_output(reader, boot_log)
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@k6_app_port}/up"))
    assert_equal "200", response.code, "the app booted but /up answered #{response.code}"
  end

  def stop_k6_app!
    pid = @k6_app_pid or return
    @k6_app_pid = nil
    begin
      Process.kill(Gem.win_platform? ? :KILL : :TERM, pid)
    rescue Errno::ESRCH
      nil
    end
    return if @k6_app_waiter.join(15)

    Process.kill(:KILL, pid)
    @k6_app_waiter.join(5)
  rescue Errno::ESRCH
    nil
  ensure
    @k6_app_log_thread&.join(5)
  end

  # --- k6 and the stress runner ---

  def k6_run_id
    @k6_run_id ||= "r#{SecureRandom.hex(4)}"
  end

  def run_k6_profile(profile, soak_duration: nil)
    k6 = StressRun.k6_binary or flunk("k6 not found: set K6_BIN or put k6 on PATH")
    key = k6_artifact_key(profile)
    summary = File.join(REPORT_DIR, "k6-summary-#{key}.json")
    FileUtils.mkdir_p(REPORT_DIR)
    FileUtils.rm_f(summary)
    env = { "K6_PROFILE" => profile, "K6_BASE_URL" => k6_base_url, "K6_API_TOKEN" => k6_api_token, "K6_RUN_ID" => k6_run_id }
    env["K6_SOAK_DURATION"] = soak_duration if soak_duration
    output, status = Open3.capture2e(env, k6, "run", "--quiet", "--no-color", "-e", "K6_PROFILE=#{profile}",
                                     "--summary-export", summary, SCRIPT, chdir: ROOT)
    File.write(File.join(REPORT_DIR, "k6-#{key}.log"), output)
    log("k6 #{profile} (exit #{status.exitstatus}):\n#{output.lines.last(45).join}")
    @k6_ran = true
    @audited_after_k6 = false
    @k6_label = key
    @k6_run = K6Run.new(profile, status.exitstatus, output, summary)
  end

  def k6_run
    @k6_run or flunk("k6 has not been run")
  end

  def run_stress_runner
    key = k6_artifact_key("stress")
    report = File.join(REPORT_DIR, "stress_report-#{key}.json")
    summary = File.join(REPORT_DIR, "k6-summary-#{key}.json")
    FileUtils.mkdir_p(REPORT_DIR)
    FileUtils.rm_f([report, summary])
    env = { "K6_BASE_URL" => k6_base_url, "K6_API_TOKEN" => k6_api_token, "K6_RUN_ID" => k6_run_id }
    output, status = Open3.capture2e(env, RbConfig.ruby, File.join(ROOT, "bin", "stress_run"),
                                     "--report", report, "--summary", summary, chdir: ROOT)
    File.write(File.join(REPORT_DIR, "stress_run-#{key}.log"), output)
    log("bin/stress_run (exit #{status.exitstatus}):\n#{output.lines.last(30).join}")
    @k6_ran = true
    @audited_after_k6 = false
    @k6_label = key
    @stress_run = StressRunResult.new(status.exitstatus, output, report)
  end

  def stress_run
    @stress_run or flunk("the stress runner has not been run")
  end

  # In the --summary-export format each threshold maps to true when it FAILED.
  def k6_threshold_state(metric)
    thresholds = k6_run.summary.dig("metrics", metric, "thresholds") or flunk("no thresholds on #{metric} in the k6 summary")
    StressRun.threshold_failed?(k6_run.summary["metrics"], metric) ? "failed" : "passed"
  end

  def k6_claims
    Claim.where("claim_number LIKE ?", "K6-#{k6_run_id}-%")
  end

  def k6_ran?
    @k6_ran == true
  end

  # Marks the audit as done for this k6 run and keeps its output as a CI artifact
  # (reports/k6/capacity-audit-<profile>.txt, LOAD_TEST_CRITERIA.md "Artifacts").
  def audited_after_k6!
    return unless k6_ran?

    @audited_after_k6 = true
    File.write(File.join(REPORT_DIR, "capacity-audit-#{@k6_label}.txt"),
               "exit #{audit_run.status}\n#{audit_run.stdout}#{audit_run.stderr}")
  end

  def audited_after_k6?
    @audited_after_k6 == true
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Reads the server's output until Puma says it is listening, the process exits, or the
  # deadline passes. IO.select blocks until output arrives; nothing polls on a timer.
  def wait_for_listening(reader)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    output = +""
    until output.include?("Listening on")
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if remaining <= 0
        stop_k6_app!
        flunk("the app did not start listening within #{BOOT_TIMEOUT}s:\n#{output}")
      end
      next unless reader.wait_readable(remaining)

      begin
        output << reader.readpartial(4096)
      rescue EOFError
        flunk("the app exited during boot (#{@k6_app_waiter.value.inspect}):\n#{output}")
      end
    end
    output
  end

  # Keeps the pipe drained so the server never blocks on a full pipe.
  def drain_server_output(reader, boot_log)
    path = File.join(REPORT_DIR, "k6-app-server-#{@k6_scenario_key || 'external'}.log")
    File.write(path, boot_log)
    @k6_app_log_thread = Thread.new do
      File.open(path, "a") { |f| IO.copy_stream(reader, f) }
    rescue IOError
      nil
    ensure
      reader.close unless reader.closed?
    end
  end
end

World(K6World)

Before("@k6_pr or @k6_nightly") do |scenario|
  self.k6_scenario = scenario
end

# The server goes before the database is cleaned (After hooks run in reverse order of
# definition, and features/support/database.rb is loaded first).
After("@k6_pr or @k6_nightly") do |scenario|
  # The capacity audit follows every k6 run (LOAD_TEST_CRITERIA.md); scenarios whose steps
  # don't run it still get it here, so no profile escapes the over-assignment check.
  if k6_ran? && !audited_after_k6? && !scenario.failed?
    run_capacity_audit
    audited_after_k6!
    unless audit_run.status.zero?
      stop_k6_app!
      raise "capacity audit after the k6 run failed (exit #{audit_run.status}):\n#{audit_run.stdout}#{audit_run.stderr}"
    end
  end
ensure
  stop_k6_app!
end
