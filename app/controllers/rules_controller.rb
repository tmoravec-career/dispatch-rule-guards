# The active rules, read-only (Q34): rule changes arrive as PRs to config/dispatch_rules.json,
# where the impact gate runs.
class RulesController < ApplicationController
  def index
    @rules = DispatchSettings.rules.rules
  end
end
