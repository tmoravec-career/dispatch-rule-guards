require_relative "../test_helper"

# QA coverage gaps found in the phase 2 verification: boundaries the scenario-derived
# tests didn't pin, and mutants (float utilization, claim-number length) that survived.
class QaCoverageTest < Minitest::Test
  include DispatchFixtures

  def matches?(op, value, actual, field: "estimated_loss")
    Dispatch::Condition.new(field: field, op: op, value: value)
                       .matches?(Dispatch::Claim.from_h("claim_number" => "C", field => actual))
  end

  # Q8 allows float thresholds; whole-dollar claims sit either side of them.
  def test_float_thresholds_at_neighbouring_whole_dollars
    { "gt" => [false, true], "gte" => [false, true], "lt" => [true, false], "lte" => [true, false] }.each do |op, expected|
      assert_equal expected, [matches?(op, 50_000.5, 50_000), matches?(op, 50_000.5, 50_001)], op
    end
    assert matches?("gte", 50_000.0, 50_000), "50000.0 and 50000 are the same threshold"
    refute matches?("gt", 50_000.0, 50_000)
  end

  def test_in_with_a_single_element
    assert matches?("in", ["TX"], "TX", field: "loss_state")
    refute matches?("in", ["TX"], "FL", field: "loss_state")
  end

  # Q3 for every operator, not just the ones the scenario uses.
  def test_missing_field_never_matches_any_operator
    claim = claim("C", "property", 10_000) # no vehicle_value
    { "eq" => 0, "in" => [0], "gt" => -1, "gte" => 0, "lt" => 1_000_000, "lte" => 1_000_000 }.each do |op, value|
      refute Dispatch::Condition.new(field: "vehicle_value", op: op, value: value).matches?(claim), op
    end
  end

  # Q16: exact rationals. With capacities this large a Float can't tell the two apart.
  def test_utilization_is_compared_exactly
    big = 10**17
    roster = Dispatch::Roster.from_h({ "adjusters" => [
      { "id" => "ADJ-001", "name" => "A", "active" => true, "licensed_states" => ["TX"], "skills" => [],
        "capacity" => 3, "open_claims" => 1 },
      { "id" => "ADJ-002", "name" => "B", "active" => true, "licensed_states" => ["TX"], "skills" => [],
        "capacity" => (3 * big) + 1, "open_claims" => big }
    ] })
    engine = Dispatch::Engine.new(Dispatch::RulesConfig.from_h({ "rules" => [] }))
    assert_equal "ADJ-002", engine.decide(claim("C", "auto", 1), roster).adjuster_id
  end

  # Q16: IDs compare as strings, so un-padded "ADJ-10" sorts before "ADJ-9".
  def test_tie_break_compares_ids_as_strings
    roster = Dispatch::Roster.from_h({ "adjusters" => %w[ADJ-9 ADJ-10].map do |id|
      { "id" => id, "name" => id, "active" => true, "licensed_states" => ["TX"], "skills" => [],
        "capacity" => 3, "open_claims" => 0 }
    end })
    engine = Dispatch::Engine.new(Dispatch::RulesConfig.from_h({ "rules" => [] }))
    assert_equal "ADJ-10", engine.decide(claim("C", "auto", 1), roster).adjuster_id
  end

  # Q11/Q13: a rule with no skills, and a rule whose queue is general_intake, still enforce licensing.
  def test_licensing_holds_for_skill_free_rules_and_general_intake
    roster = Dispatch::Roster.from_h({ "adjusters" => [
      { "id" => "ADJ-001", "name" => "A", "active" => true, "licensed_states" => ["TX"], "skills" => [],
        "capacity" => 5, "open_claims" => 0 }
    ] })
    [{ "rules" => [] },
     { "rules" => [{ "id" => "any", "priority" => 1, "queue" => "q", "required_skills" => [], "conditions" => [{ "field" => "line_of_business", "op" => "in", "value" => %w[auto property liability] }] }] },
     { "rules" => [{ "id" => "gi", "priority" => 1, "queue" => "general_intake", "required_skills" => [], "conditions" => [{ "field" => "line_of_business", "op" => "in", "value" => %w[auto property liability] }] }] }]
      .each do |rules|
        result = Dispatch::Engine.new(Dispatch::RulesConfig.from_h(rules)).dispatch(claim("C", "auto", 1, nil, false, "CA"), roster)
        assert_equal "no_qualified_adjuster", result.reason_code, rules.inspect
        assert_nil result.adjuster_id
      end
  end

  def test_roster_rejects_lowercase_or_padded_licensed_states
    ["tx", " TX", "TX ", "*"].each do |state|
      error = assert_raises(Dispatch::ConfigError, state.inspect) do
        Dispatch::Roster.from_h({ "adjusters" => [
          { "id" => "ADJ-001", "name" => "A", "active" => true, "licensed_states" => [state], "skills" => [],
            "capacity" => 5, "open_claims" => 0 }
        ] })
      end
      assert_equal [%w[invalid_value adjusters[0].licensed_states]], error.errors.map { |e| [e.code, e.path] }
    end
  end

  # Q1: claim_number is at most 32 characters; the existing test only covers 33.
  def test_claim_number_of_exactly_32_characters_loads
    claims = Dispatch::Claim.load_all([{ "claim_number" => "X" * 32, "line_of_business" => "auto",
                                         "estimated_loss" => 1, "loss_state" => "TX" }])
    assert_equal 32, claims.first.claim_number.length
  end

  def test_crlf_rules_file_loads
    json = JSON.pretty_generate(base_rules_hash).gsub("\n", "\r\n")
    assert_equal base_config.to_h, Dispatch::RulesConfig.parse(json).to_h
  end

  def test_webhook_refuses_sequence_zero
    result = Dispatch::Engine.new(base_config).decide(claim("C", "auto", 1), roster)
    assert_raises(ArgumentError) do
      Dispatch::Webhook.payload(claim("C", "auto", 1), result, event_id: "e", occurred_at: Time.now, sequence: 0)
    end
  end

  # Contract (Q23) for the outcomes the existing contract test doesn't build: fall-through
  # (matched_rule null) unassigned and assigned, and no_qualified_adjuster; plus sequence 0.
  def test_fall_through_and_no_qualified_payloads_conform_to_contract
    skip "contract check runs under bundle exec or CONTRACTS=1" unless defined?(Bundler) || ENV["CONTRACTS"] == "1"
    begin
      require "json_schemer"
    rescue LoadError
      skip "json_schemer not available outside the bundle"
    end
    schema = JSONSchemer.schema(Pathname.new(File.expand_path("../../contracts/claim_dispatched.schema.json", __dir__)),
                                format: true)
    engine = Dispatch::Engine.new(base_config)
    time = Time.utc(2026, 10, 6, 9, 0, 5)
    cases = { claim("C1", "liability", 1, nil, false, "TX") => "qualified_adjusters_at_capacity", # fall-through, TX all full
              claim("C4", "liability", 1, nil, false, "WY") => "no_qualified_adjuster", # fall-through, nobody licensed
              claim("C2", "liability", 1, nil, false, "NY") => "assigned",              # fall-through, ADJ-006
              claim("C3", "auto", 1, 120_000, false, "WY") => "no_qualified_adjuster" } # luxury, nobody in WY
    cases.each do |c, reason|
      fresh = roster("ADJ-001" => { "open_claims" => 3 }, "ADJ-002" => { "open_claims" => 3 },
                     "ADJ-003" => { "open_claims" => 4 })
      result = engine.dispatch(c, fresh)
      assert_equal reason, result.reason_code, c.claim_number
      payload = JSON.parse(JSON.generate(Dispatch::Webhook.payload(c, result, event_id: Dispatch::Webhook.generate_event_id,
                                                                               occurred_at: time, sequence: 1)))
      assert schema.valid?(payload), schema.validate(payload).map { |e| e["error"] }.inspect
      payload["sequence"] = 0
      refute schema.valid?(payload), "sequence 0 must be rejected"
    end
  end
end
