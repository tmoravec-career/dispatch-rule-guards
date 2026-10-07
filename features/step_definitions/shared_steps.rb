# STEP_GLOSSARY.md sections 1-2: shared setup and assertions.
# Phase 2 builds plain-Ruby objects only (@engine); phase 3 adds the app-side
# behaviour for @ui/@api scenarios to these same definitions.

Given("the dispatch rules:") do |table|
  self.rules_hash = Tables.rules_hash(table)
  # Validate now so a malformed table fails at the step that defines it.
  Dispatch::RulesConfig.from_h(rules_hash)
end

Given("the adjuster roster:") do |table|
  self.roster = Dispatch::Roster.from_h(Tables.roster_hash(table))
end

Given("adjuster {string} has {int} open claim(s)") do |id, count|
  roster.set_open_claims(id, count)
end

Given("adjuster {string} is inactive") do |id|
  roster.update(id, active: false)
end

Given("rule {string} has condition {string}") do |rule_id, clause|
  Tables.replace_condition(rules_hash, rule_id, clause)
  Dispatch::RulesConfig.from_h(rules_hash)
end

Then("adjuster {string} should have {int} open claim(s)") do |id, count|
  assert_equal count, roster.find(id).open_claims
end
