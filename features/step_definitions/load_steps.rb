# STEP_GLOSSARY.md section 9: the k6 runs (@k6_pr on every PR, @k6_nightly nightly).
# The harness (app server, k6, stress runner) is features/support/k6_world.rb; the capacity
# audit steps are in app_steps.rb.

Given("the app is running with the seed roster and rules") do
  use_seed_roster_and_rules!
end

Given("the app adds {int} ms of latency to every API response") do |ms|
  self.k6_app_latency_ms = ms
end

When("I run the k6 {string} profile") do |profile|
  run_k6_profile(profile)
end

When("I run the k6 {string} profile with duration {string}") do |profile, duration|
  run_k6_profile(profile, soak_duration: duration)
end

Then("k6 exits with status {int}") do |status|
  assert_equal status, k6_run.status, "k6 #{k6_run.profile} output:\n#{k6_run.output}"
end

Then("the k6 summary reports threshold {string} as {string}") do |metric, state|
  assert_includes %w[passed failed], state
  assert_equal state, k6_threshold_state(metric), "k6 #{k6_run.profile} output:\n#{k6_run.output.lines.last(40).join}"
end

Then("every claim created during the k6 run has a terminal dispatch result") do
  claims = k6_claims.to_a
  refute_empty claims, "the k6 run created no claims with prefix K6-#{k6_run_id}-"
  unassigned_codes = [Dispatch::Result::NO_QUALIFIED_ADJUSTER, Dispatch::Result::QUALIFIED_ADJUSTERS_AT_CAPACITY]
  not_terminal = claims.reject do |claim|
    case claim.status
    when "assigned" then claim.adjuster_id.present? && claim.reason_code == Dispatch::Result::ASSIGNED
    when "unassigned" then claim.adjuster_id.nil? && unassigned_codes.include?(claim.reason_code)
    else false
    end
  end
  assert_empty not_terminal.map { |c| [c.claim_number, c.status, c.adjuster_id, c.reason_code] },
               "#{not_terminal.size} of #{claims.size} k6 claims have no terminal dispatch result"
end

Then("the k6 run created CAT-event property claims in each of {string}") do |states|
  states.split(",").map(&:strip).each do |state|
    assert k6_claims.where(line_of_business: "property", cat_event: true, loss_state: state).exists?,
           "the k6 run created no CAT-event property claim in #{state}"
  end
end

Then("the k6 run lasted between {int} and {int} seconds") do |low, high|
  # state.testRunDurationMs, or count / rate of a counter where k6's export omits `state`.
  duration_ms = StressRun.test_run_duration_ms(k6_run.summary) or flunk("the k6 summary has no run duration")
  seconds = duration_ms / 1000.0
  assert_operator seconds, :>=, low, "the k6 run lasted #{seconds.round(1)}s"
  assert_operator seconds, :<=, high, "the k6 run lasted #{seconds.round(1)}s"
end

When("I run the stress runner") do
  run_stress_runner
end

Then("the stress runner exits with status {int}") do |status|
  assert_equal status, stress_run.status, "bin/stress_run output:\n#{stress_run.output}"
end

Then("the stress report includes {string}") do |key|
  assert stress_run.report.key?(key), "stress_report.json has no #{key.inspect}: #{stress_run.report.inspect}"
end

Then("the stress report at {string} is {json}") do |key, expected|
  assert stress_run.report.key?(key), "stress_report.json has no #{key.inspect}"
  assert_equal expected, stress_run.report[key], "stress_report.json: #{JSON.pretty_generate(stress_run.report)}"
end
