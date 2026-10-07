# Dispatch Rules Guard engine. Plain Ruby, stdlib only: it must load with
# `ruby -Ilib` and no bundle so bin/rule_diff runs in CI without the web app.
module Dispatch
  # The five claim fields a rule condition may reference (Q7).
  ROUTING_FIELDS = %w[line_of_business estimated_loss vehicle_value cat_event loss_state].freeze
  NUMERIC_FIELDS = %w[estimated_loss vehicle_value].freeze
  LINES_OF_BUSINESS = %w[auto property liability].freeze
  US_STATES = %w[
    AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM
    NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY
  ].freeze

  # Queue for claims that match no rule. It has no required skills (Q13).
  GENERAL_INTAKE = "general_intake".freeze
end

require "dispatch/errors"
require "dispatch/claim"
require "dispatch/claim_input"
require "dispatch/money_input"
require "dispatch/condition"
require "dispatch/rule"
require "dispatch/rules_config"
require "dispatch/adjuster"
require "dispatch/roster"
require "dispatch/result"
require "dispatch/engine"
require "dispatch/webhook"
require "dispatch/scenario_generator"
require "dispatch/gate/boundary_probes"
require "dispatch/gate/policy"
require "dispatch/gate/impact"
require "dispatch/gate/markdown_report"
