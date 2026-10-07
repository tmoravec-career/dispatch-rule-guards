require_relative "../test_helper"

# Rules config validation at load (OPEN_QUESTIONS Q6-Q12; dispatch_routing @validation).
class RulesConfigTest < Minitest::Test
  def single_rule(conditions, extra = {})
    { "rules" => [{ "id" => "r1", "priority" => 1, "queue" => "q1", "required_skills" => [],
                    "conditions" => conditions }.merge(extra)] }
  end

  def errors_for(hash_or_json)
    if hash_or_json.is_a?(String)
      Dispatch::RulesConfig.parse(hash_or_json)
    else
      Dispatch::RulesConfig.from_h(hash_or_json)
    end
    flunk "expected the config to be rejected"
  rescue Dispatch::ConfigError => e
    e.errors.map { |err| [err.code, err.path] }
  end

  def test_well_formed_config_loads_sorted_by_priority
    config = DispatchFixtures.base_config
    assert_equal 7, config.rules.size
    assert_equal %w[cat_large_loss luxury_auto auto_fast_track auto_standard auto_complex coastal_property property_standard],
                 config.rules.map(&:id)

    reversed = DispatchFixtures.base_rules_hash
    reversed["rules"].reverse!
    assert_equal config.rules.map(&:id), Dispatch::RulesConfig.from_h(reversed).rules.map(&:id)
  end

  # Q55 G2: a rule must have at least one condition, reported with any other errors.
  def test_rule_with_no_conditions_is_rejected
    assert_equal [["invalid_value", "rules[0].conditions"]], errors_for(single_rule([]))
    hash = { "rules" => [
      { "id" => "a", "priority" => 1, "queue" => "q", "required_skills" => [], "conditions" => [] },
      { "id" => "b", "priority" => 1, "queue" => "q", "required_skills" => [],
        "conditions" => [{ "field" => "vehicle_value", "op" => "gtee", "value" => 1 }] }
    ] }
    assert_equal [["duplicate_priority", "rules[1].priority"], ["invalid_value", "rules[0].conditions"],
                  ["unknown_operator", "rules[1].conditions[0].op"]], errors_for(hash).sort
  end

  def test_empty_rule_set_is_valid
    assert_equal 0, Dispatch::RulesConfig.from_h({ "rules" => [] }).rules.size
  end

  def test_parse_accepts_json_text
    assert_equal 7, Dispatch::RulesConfig.parse(JSON.generate(DispatchFixtures::BASE_RULES)).rules.size
  end

  def test_floats_are_valid_thresholds
    config = Dispatch::RulesConfig.from_h(single_rule([{ "field" => "estimated_loss", "op" => "gt", "value" => 100.5 }]))
    assert_equal 100.5, config.rules.first.conditions.first.value
  end

  MALFORMED_CONDITIONS = [
    [{ "field" => "vehicle_value", "op" => "gtee", "value" => 100_000 }, "unknown_operator", ".op"],
    [{ "field" => "vehicle_value", "op" => "=>", "value" => 100_000 }, "unknown_operator", ".op"],
    [{ "field" => "vehicle_valu", "op" => "gte", "value" => 100_000 }, "unknown_field", ".field"],
    [{ "field" => "vehicle_value", "op" => "gte", "value" => 100_000, "incl" => true }, "unknown_field", ".incl"],
    [{ "field" => "vehicle_value", "op" => "gte", "value" => "100k" }, "non_numeric_threshold", ".value"],
    [{ "field" => "vehicle_value", "op" => "gte", "value" => "100000" }, "non_numeric_threshold", ".value"],
    [{ "field" => "estimated_loss", "op" => "lt", "value" => nil }, "non_numeric_threshold", ".value"],
    [{ "field" => "estimated_loss", "op" => "gt", "value" => true }, "non_numeric_threshold", ".value"],
    [{ "field" => "loss_state", "op" => "in", "value" => "TX" }, "invalid_value", ".value"],
    [{ "field" => "loss_state", "op" => "in", "value" => [] }, "invalid_value", ".value"],
    [{ "field" => "loss_state", "op" => "eq", "value" => ["TX"] }, "invalid_value", ".value"],
    [{ "field" => "loss_state", "op" => "eq" }, "missing_field", ".value"],
    [{ "op" => "eq", "value" => "TX" }, "missing_field", ".field"]
  ].freeze

  MALFORMED_CONDITIONS.each_with_index do |(condition, code, suffix), i|
    define_method("test_malformed_condition_#{i}_#{code}") do
      errors = errors_for(single_rule([condition]))
      assert_includes errors, [code, "rules[0].conditions[0]#{suffix}"], "condition #{condition.inspect}"
    end
  end

  # Q55: 1e400 parses to Infinity and is rejected at load, never reaching the probes (D2).
  def test_non_finite_thresholds_are_rejected
    ['{"field":"estimated_loss","op":"gte","value":1e400}',
     '{"field":"estimated_loss","op":"lt","value":-1e400}',
     '{"field":"vehicle_value","op":"eq","value":1e400}',
     '{"field":"vehicle_value","op":"in","value":[1, 1e400]}'].each do |condition|
      json = %({"rules":[{"id":"r1","priority":1,"queue":"q1","required_skills":[],"conditions":[#{condition}]}]})
      assert_equal [["non_numeric_threshold", "rules[0].conditions[0].value"]], errors_for(json), condition
    end
  end

  # Q55 G3: operators and values must agree with the field's type.
  TYPE_MISMATCHES = [
    [{ "field" => "loss_state", "op" => "gt", "value" => 5 }, ".op"],
    [{ "field" => "cat_event", "op" => "gte", "value" => 1 }, ".op"],
    [{ "field" => "cat_event", "op" => "eq", "value" => "true" }, ".value"],
    [{ "field" => "estimated_loss", "op" => "eq", "value" => "5000" }, ".value"],
    [{ "field" => "vehicle_value", "op" => "eq", "value" => true }, ".value"],
    [{ "field" => "line_of_business", "op" => "eq", "value" => 1 }, ".value"],
    [{ "field" => "line_of_business", "op" => "in", "value" => ["auto", 1] }, ".value"],
    [{ "field" => "loss_state", "op" => "in", "value" => [true] }, ".value"]
  ].freeze

  TYPE_MISMATCHES.each_with_index do |(condition, suffix), i|
    define_method("test_type_mismatch_#{i}") do
      assert_equal [["invalid_value", "rules[0].conditions[0]#{suffix}"]], errors_for(single_rule([condition])), condition.inspect
    end
  end

  def test_matching_types_load
    conditions = [{ "field" => "cat_event", "op" => "in", "value" => [true] },
                  { "field" => "vehicle_value", "op" => "eq", "value" => 100_000 },
                  { "field" => "estimated_loss", "op" => "in", "value" => [1, 2.5] },
                  { "field" => "loss_state", "op" => "eq", "value" => "TX" }]
    assert_equal 4, Dispatch::RulesConfig.from_h(single_rule(conditions)).rules.first.conditions.size
  end

  # Q55 minor: an invalid priority is not also a duplicate.
  def test_invalid_priorities_are_not_reported_as_duplicates
    hash = { "rules" => %w[a b].map do |id|
      { "id" => id, "priority" => 1.5, "queue" => "q", "required_skills" => [],
        "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }] }
    end }
    assert_equal [["invalid_value", "rules[0].priority"], ["invalid_value", "rules[1].priority"]], errors_for(hash)
  end

  def test_licensing_cannot_be_configured
    assert_includes errors_for({ "enforce_licensing" => false, "rules" => [] }), ["unknown_field", "enforce_licensing"]
    assert_includes errors_for(single_rule([], "ignore_licensing" => true)), ["unknown_field", "rules[0].ignore_licensing"]
    assert_includes errors_for(single_rule([], "licensed_states" => %w[TX GA])), ["unknown_field", "rules[0].licensed_states"]
  end

  def test_unknown_rule_field
    hash = { "rules" => [{ "id" => "luxury_auto", "priority" => 20, "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }], "queue" => "luxury_auto",
                           "required_skils" => ["luxury_vehicle"] }] }
    errors = errors_for(hash)
    assert_includes errors, ["unknown_field", "rules[0].required_skils"]
    assert_includes errors, ["missing_field", "rules[0].required_skills"]
  end

  def test_missing_rule_field
    hash = { "rules" => [{ "id" => "luxury_auto", "priority" => 20, "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }], "required_skills" => [] }] }
    assert_equal [["missing_field", "rules[0].queue"]], errors_for(hash)
  end

  def test_missing_rules_key
    assert_equal [["missing_field", "rules"]], errors_for({})
  end

  def test_duplicate_priority_points_at_later_rule
    hash = { "rules" => [
      { "id" => "luxury_auto", "priority" => 20, "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }], "queue" => "luxury_auto", "required_skills" => [] },
      { "id" => "auto_standard", "priority" => 20, "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }], "queue" => "auto_standard", "required_skills" => [] }
    ] }
    assert_equal [["duplicate_priority", "rules[1].priority"]], errors_for(hash)
  end

  def test_duplicate_rule_id_points_at_later_rule
    hash = { "rules" => [
      { "id" => "luxury_auto", "priority" => 20, "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }], "queue" => "luxury_auto", "required_skills" => [] },
      { "id" => "luxury_auto", "priority" => 30, "conditions" => [{ "field" => "cat_event", "op" => "eq", "value" => true }], "queue" => "luxury_auto", "required_skills" => [] }
    ] }
    assert_equal [["duplicate_rule_id", "rules[1].id"]], errors_for(hash)
  end

  def test_type_errors_on_rule_keys
    hash = { "rules" => [{ "id" => "", "priority" => 1.5, "conditions" => {}, "queue" => 7, "required_skills" => ["a", 1] }] }
    assert_equal [["invalid_value", "rules[0].id"], ["invalid_value", "rules[0].priority"],
                  ["invalid_value", "rules[0].conditions"], ["invalid_value", "rules[0].queue"],
                  ["invalid_value", "rules[0].required_skills[1]"]].sort,
                 errors_for(hash).sort
  end

  def test_every_problem_is_reported_together
    json = <<~JSON
      {"rules": [
        {"id": "ok_rule", "priority": 10, "conditions": [{"field": "estimated_loss", "op": "gte", "value": 50000}], "queue": "q1", "required_skills": []},
        {"id": "typo_op", "priority": 20, "conditions": [{"field": "estimated_loss", "op": "gtee", "value": 1}], "queue": "q2", "required_skills": []},
        {"id": "bad_num", "priority": 20, "conditions": [{"field": "vehicle_value", "op": "gte", "value": "60k"}], "queue": "q3", "required_skills": []}
      ]}
    JSON
    assert_equal [["duplicate_priority", "rules[2].priority"],
                  ["non_numeric_threshold", "rules[2].conditions[0].value"],
                  ["unknown_operator", "rules[1].conditions[0].op"]],
                 errors_for(json).sort
  end

  def test_errors_carry_readable_messages
    Dispatch::RulesConfig.from_h(single_rule([{ "field" => "vehicle_value", "op" => "gtee", "value" => 1 }]))
  rescue Dispatch::ConfigError => e
    refute_empty e.errors.first.message
    assert_match(/unknown_operator at rules\[0\]\.conditions\[0\]\.op/, e.message)
  end

  def test_malformed_json
    assert_equal [["malformed_json", "$"]], errors_for("{not json")
  end

  # Q55: not valid UTF-8 -> malformed_json at "$"; a leading BOM is accepted.
  def test_non_utf8_text_is_malformed_json
    assert_equal [["malformed_json", "$"]], errors_for('{"rules": [{"id": "caf' + "\xE9".b + '"}]}')
  end

  def test_non_utf8_file_is_malformed_json_naming_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "latin1.json")
      File.binwrite(path, '{"rules": [], "x": "' + "\xE9".b + '"}')
      error = assert_raises(Dispatch::ConfigError) { Dispatch::RulesConfig.load_file(path) }
      assert_equal [["malformed_json", "$"]], error.errors.map { |e| [e.code, e.path] }
      assert_includes error.message, path
    end
  end

  def test_leading_bom_is_stripped
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bom.json")
      File.binwrite(path, "\xEF\xBB\xBF".b + JSON.generate(DispatchFixtures::BASE_RULES))
      assert_equal 7, Dispatch::RulesConfig.load_file(path).rules.size
    end
    assert_equal 0, Dispatch::RulesConfig.parse("﻿{\"rules\": []}").rules.size
  end

  def test_non_object_root
    assert_equal [["invalid_value", "$"]], errors_for("[]")
  end

  def test_load_file_names_the_file_in_the_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.json")
      File.write(path, '{"rules": [{"id": "x"}]}')
      error = assert_raises(Dispatch::ConfigError) { Dispatch::RulesConfig.load_file(path) }
      assert_equal path, error.source
      assert_includes error.message, path
    end
  end
end
