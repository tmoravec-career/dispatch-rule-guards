# STEP_GLOSSARY.md sections 1-2: shared setup and assertions. One definition per phrase:
# @engine scenarios build plain-Ruby objects; @api/@ui/@load scenarios (app_layer?) make
# the same data live in the app.

Given("the dispatch rules:") do |table|
  self.rules_hash = Tables.rules_hash(table)
  # Validate now so a malformed table fails at the step that defines it.
  Dispatch::RulesConfig.from_h(rules_hash)
  activate_rules! if app_layer?
end

Given("the adjuster roster:") do |table|
  self.roster = Dispatch::Roster.from_h(Tables.roster_hash(table))
  load_app_roster!(roster) if app_layer?
end

# In the app this sets the stored counter directly, bypassing dispatch and validation, so
# @audit scenarios can leave an adjuster over capacity, as a lost race would.
Given("adjuster {string} has {int} open claim(s)") do |id, count|
  if app_layer?
    assert_equal 1, Adjuster.where(id: id).update_all(open_claims: count), "no adjuster #{id} in the app's roster"
  else
    roster.set_open_claims(id, count)
  end
end

Given("adjuster {string} is inactive") do |id|
  if app_layer?
    assert_equal 1, Adjuster.where(id: id).update_all(active: false), "no adjuster #{id} in the app's roster"
  else
    roster.update(id, active: false)
  end
end

Given("rule {string} has condition {string}") do |rule_id, clause|
  Tables.replace_condition(rules_hash, rule_id, clause)
  Dispatch::RulesConfig.from_h(rules_hash)
  activate_rules! if app_layer?
end

Then("adjuster {string} should have {int} open claim(s)") do |id, count|
  actual = app_layer? ? app_adjuster(id).open_claims : roster.find(id).open_claims
  assert_equal count, actual
end

Then("claim {string} does not exist") do |claim_number|
  refute Claim.exists?(claim_number: claim_number), "claim #{claim_number} was persisted"
end
