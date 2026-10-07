# STEP_GLOSSARY.md section 3: engine dispatch (dispatch_routing.feature).

When("a claim is dispatched:") do |table|
  claims = Tables.claim_hashes(table)
  assert_equal 1, claims.size, "this step takes exactly one claim row"
  dispatch_claims(claims)
end

When("these claims are dispatched in order:") do |table|
  dispatch_claims(Tables.claim_hashes(table))
end

When("the same claim is dispatched again against a fresh copy of the roster") do
  redispatch_against_fresh_roster
end

Then("the claim is routed to queue {string} by rule {string}") do |queue, rule|
  assert_equal [queue, rule], [result.queue, result.matched_rule]
end

Then("the claim is routed to queue {string} with no matched rule") do |queue|
  assert_equal queue, result.queue
  assert_nil result.matched_rule
end

Then("the claim is assigned to adjuster {string}") do |adjuster|
  assert_equal adjuster, result.adjuster_id, result.reason
end

Then("the claim is unassigned with reason code {string}") do |code|
  assert_nil result.adjuster_id, "expected no adjuster, got #{result.adjuster_id}"
  assert_equal code, result.reason_code
end

Then("the reason code is {string}") do |code|
  assert_equal code, result.reason_code
end

Then("the result includes a human-readable reason") do
  assert_kind_of String, result.reason
  refute_empty result.reason.strip
end

Then("the dispatch results are:") do |table|
  expected = table.hashes.map do |row|
    [row["claim_number"], row["queue"], row["matched_rule"].to_s.strip, row["adjuster"].to_s.strip, row["reason_code"]]
  end
  actual = results.map do |r|
    [r.claim_number, r.queue, r.matched_rule.to_s, r.adjuster_id.to_s, r.reason_code]
  end
  assert_equal expected, actual
end

Then("both dispatch results are identical") do
  assert_equal result.to_h, second_result.to_h
end
