$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "json"
require "tmpdir"
require "dispatch"

# The webhook contract checks need json_schemer (a gem, ~1 s to load), so they run only
# under `bundle exec` or with CONTRACTS=1. When any of them actually skipped in this run,
# say so after the summary, so a plain run's pass count isn't mistaken for full coverage.
CONTRACT_TESTS_ENABLED = !!(defined?(Bundler) || ENV["CONTRACTS"] == "1")

module ContractSkipNotice
  @skipped = 0

  class << self
    attr_accessor :skipped
  end

  # Counts tests that skipped with a contract-layer message (ours and QA's both say "contract").
  def after_teardown
    super
    ContractSkipNotice.skipped += 1 if skipped? && failure.message.match?(/\bcontract\b/i)
  end
end
Minitest::Test.prepend(ContractSkipNotice)

Minitest.after_run do
  next if ContractSkipNotice.skipped.zero?

  puts <<~NOTE

    NOTE: #{ContractSkipNotice.skipped} webhook contract test(s) (JSON Schema, json_schemer) were SKIPPED in this run.
    To run them too:
      CONTRACTS=1 bundle exec ruby -Ilib -e 'Dir["test/**/*_test.rb"].each { |f| require "./\#{f}" }'
  NOTE
end

# Shared fixtures: the Background roster and rules from features/dispatch_routing.feature
# and features/rule_change_gate.feature, plus small builders.
module DispatchFixtures
  BASE_RULES = {
    "rules" => [
      { "id" => "cat_large_loss", "priority" => 10, "queue" => "cat_large_loss", "required_skills" => %w[cat large_loss],
        "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true },
                         { "field" => "estimated_loss", "op" => "gte", "value" => 50_000 }] },
      { "id" => "luxury_auto", "priority" => 20, "queue" => "luxury_auto", "required_skills" => %w[luxury_vehicle],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                         { "field" => "vehicle_value", "op" => "gte", "value" => 100_000 }] },
      { "id" => "auto_fast_track", "priority" => 30, "queue" => "auto_fast_track", "required_skills" => %w[auto],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                         { "field" => "estimated_loss", "op" => "lt", "value" => 5_000 }] },
      { "id" => "auto_standard", "priority" => 40, "queue" => "auto_standard", "required_skills" => %w[auto],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" },
                         { "field" => "estimated_loss", "op" => "lte", "value" => 25_000 }] },
      { "id" => "auto_complex", "priority" => 50, "queue" => "auto_complex", "required_skills" => %w[auto large_loss],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "auto" }] },
      { "id" => "coastal_property", "priority" => 60, "queue" => "coastal_property", "required_skills" => %w[property cat],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "property" },
                         { "field" => "loss_state", "op" => "in", "value" => %w[TX FL LA] }] },
      { "id" => "property_standard", "priority" => 70, "queue" => "property_standard", "required_skills" => %w[property],
        "conditions" => [{ "field" => "line_of_business", "op" => "eq", "value" => "property" }] }
    ]
  }.freeze

  ROSTER = [
    ["ADJ-001", "Avery Chen", true,  %w[TX FL],    %w[auto luxury_vehicle],           3],
    ["ADJ-002", "Blake Diaz", true,  %w[TX FL],    %w[auto luxury_vehicle],           3],
    ["ADJ-003", "Casey Ford", true,  %w[TX LA],    %w[property cat large_loss],       4],
    ["ADJ-004", "Devon Gray", true,  %w[CA NV AZ], %w[luxury_vehicle],                2],
    ["ADJ-005", "Emery Hart", true,  %w[CA AZ],    %w[auto large_loss],               4],
    ["ADJ-006", "Finley Ito", true,  %w[NY NJ],    %w[auto property],                 4],
    ["ADJ-007", "Gale Jones", false, %w[CA NY],    %w[auto luxury_vehicle property],  5],
    ["ADJ-008", "Harper Kim", true,  %w[FL GA],    %w[property cat large_loss],       3]
  ].map do |id, name, active, states, skills, capacity|
    { "id" => id, "name" => name, "active" => active, "licensed_states" => states,
      "skills" => skills, "capacity" => capacity, "open_claims" => 0 }
  end.freeze

  module_function

  def deep_copy(obj)
    JSON.parse(JSON.generate(obj))
  end

  def base_rules_hash
    deep_copy(BASE_RULES)
  end

  def base_config
    Dispatch::RulesConfig.from_h(base_rules_hash)
  end

  def roster(overrides = {})
    adjusters = deep_copy(ROSTER).map { |a| a.merge(overrides.fetch(a["id"], {})) }
    Dispatch::Roster.from_h({ "adjusters" => adjusters })
  end

  def claim(number, lob, loss, vehicle = nil, cat = false, state = "TX")
    Dispatch::Claim.new(claim_number: number, line_of_business: lob, estimated_loss: loss,
                        vehicle_value: vehicle, cat_event: cat, loss_state: state)
  end

  # Returns a copy of `rules_hash` where the condition on `field` in rule `rule_id`
  # is replaced, mirroring the "with these condition changes" step.
  def with_condition(rules_hash, rule_id, field, op, value)
    copy = deep_copy(rules_hash)
    rule = copy["rules"].find { |r| r["id"] == rule_id }
    rule["conditions"].reject! { |c| c["field"] == field }
    rule["conditions"] << { "field" => field, "op" => op, "value" => value }
    copy
  end

  def demo_proposed_hash
    h = with_condition(base_rules_hash, "luxury_auto", "vehicle_value", "gte", 60_000)
    with_condition(h, "cat_large_loss", "estimated_loss", "gt", 50_000)
  end

  # The 10 replay claims from the rule_change_gate Background.
  REPLAY_CLAIMS = [
    ["CLM-2001", "auto",     12_000, 65_000,  false, "CA"],
    ["CLM-2002", "auto",     15_000, 72_000,  false, "CA"],
    ["CLM-2003", "auto",     9_000,  88_000,  false, "CA"],
    ["CLM-2004", "auto",     20_000, 120_000, false, "CA"],
    ["CLM-2005", "auto",     14_000, 70_000,  false, "TX"],
    ["CLM-2006", "property", 50_000, nil,     true,  "TX"],
    ["CLM-2007", "property", 80_000, nil,     true,  "FL"],
    ["CLM-2008", "auto",     3_000,  22_000,  false, "NY"],
    ["CLM-2009", "property", 10_000, nil,     false, "NY"],
    ["CLM-2010", "auto",     8_000,  30_000,  false, "AZ"]
  ].map do |number, lob, loss, vehicle, cat, state|
    DispatchFixtures.claim(number, lob, loss, vehicle, cat, state)
  end.freeze
end
