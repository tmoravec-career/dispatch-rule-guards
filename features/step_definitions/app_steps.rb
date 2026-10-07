# App-side steps shared across layers: the controllable clock (STEP_GLOSSARY.md section 2a),
# dispatching through the app's own service (section 5), and the capacity audit and
# concurrency race (section 9).

# --- clock ---------------------------------------------------------------------------

Given("the clock is frozen at {string}") do |iso8601|
  Clock.freeze_at(Time.iso8601(iso8601))
end

When("the clock advances by {int} second(s)") do |seconds|
  Clock.advance(seconds)
end

# --- dispatching in the app ----------------------------------------------------------------

Given("these claims have been dispatched in order:") do |table|
  dispatch_in_app(Tables.claim_hashes(table))
end

# --- capacity audit -------------------------------------------------------------------------

When("I run the capacity audit") do
  run_capacity_audit
end

Then("the capacity audit exits with status {int}") do |status|
  assert_equal status, audit_run.status, "stdout:\n#{audit_run.stdout}\nstderr:\n#{audit_run.stderr}"
end

Then("the capacity audit reports no violations") do
  assert_empty audit_run.violations, audit_run.stdout
  assert_match(/, 0 over capacity$/, audit_run.stdout)
end

Then("the capacity audit reports these violations:") do |table|
  expected = table.hashes.map { |row| row.values_at("adjuster", "open_claims", "capacity") }
  assert_equal expected.sort, audit_run.violations.sort, audit_run.stdout
end

# --- concurrency --------------------------------------------------------------------------------

When("{int} copies of this claim are dispatched concurrently:") do |copies, table|
  claims = Tables.claim_hashes(table)
  assert_equal 1, claims.size, "this step takes exactly one claim row"
  base = claims.first
  @concurrent_claims = dispatch_concurrently(Array.new(copies) do |i|
    base.merge("claim_number" => format("%<number>s-%<copy>02d", number: base.fetch("claim_number"), copy: i + 1))
  end)
end

Then("{int} of them are assigned to adjuster {string}") do |count, adjuster|
  claims = Claim.where(id: @concurrent_claims.map(&:id))
  assert_equal count, claims.where(status: "assigned", adjuster_id: adjuster).count,
               claims.group(:status, :adjuster_id).count.inspect
end

Then("{int} of them are unassigned with reason code {string}") do |count, reason_code|
  claims = Claim.where(id: @concurrent_claims.map(&:id))
  assert_equal count, claims.where(status: "unassigned", adjuster_id: nil, reason_code: reason_code).count,
               claims.group(:status, :reason_code).count.inspect
end
