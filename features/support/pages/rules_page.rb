require_relative "base_page"

# The active rules in evaluation order (rule-row-<id>), ending with general_intake, and
# the licensing-guardrail notice. Read-only (Q34).
class RulesPage < BasePage
  PATH = "/rules".freeze
  CONTAINER = "rules-page".freeze
end
