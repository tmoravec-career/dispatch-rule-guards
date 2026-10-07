require_relative "../test_helper"

# API claim input validation (Q1, Q2, Q20, Q50): field-level codes, all reported together.
class ClaimInputTest < Minitest::Test
  VALID = { "claim_number" => "CLM-1", "line_of_business" => "auto", "estimated_loss" => 12_000,
            "vehicle_value" => 30_000, "cat_event" => false, "loss_state" => "TX" }.freeze

  def errors_for(changes = {}, without: [])
    body = VALID.merge(changes)
    without.each { |key| body.delete(key) }
    Dispatch::ClaimInput.validate(body).last.map(&:to_a)
  end

  def test_valid_claim_is_normalized
    attrs, errors = Dispatch::ClaimInput.validate(VALID)
    assert_empty errors
    assert_equal VALID, attrs
  end

  def test_optional_fields_default
    attrs, errors = Dispatch::ClaimInput.validate(VALID.reject { |k, _| %w[vehicle_value cat_event].include?(k) })
    assert_empty errors
    assert_nil attrs["vehicle_value"]
    assert_equal false, attrs["cat_event"]
  end

  def test_null_optional_fields_are_accepted
    attrs, errors = Dispatch::ClaimInput.validate(VALID.merge("vehicle_value" => nil, "cat_event" => nil))
    assert_empty errors
    assert_nil attrs["vehicle_value"]
    assert_equal false, attrs["cat_event"]
  end

  def test_money_codes_follow_q50
    {
      "lots" => "invalid_value", "$1,200" => "invalid_value", "12000" => "invalid_value", true => "invalid_value",
      [] => "invalid_value", {} => "invalid_value", -1 => "out_of_range", 12_000.5 => "not_an_integer",
      Float::INFINITY => "invalid_value", nil => "missing"
    }.each do |value, code|
      assert_equal [["estimated_loss", code]], errors_for({ "estimated_loss" => value }), "estimated_loss = #{value.inspect}"
    end
    {
      "x" => "invalid_value", "$120,000" => "invalid_value", [] => "invalid_value", {} => "invalid_value",
      99_999.99 => "not_an_integer", -5 => "out_of_range"
    }.each do |value, code|
      assert_equal [["vehicle_value", code]], errors_for({ "vehicle_value" => value }), "vehicle_value = #{value.inspect}"
    end
  end

  def test_whole_number_floats_are_integers
    attrs, errors = Dispatch::ClaimInput.validate(VALID.merge("estimated_loss" => 12_000.0))
    assert_empty errors
    assert_equal 12_000, attrs["estimated_loss"]
    assert_kind_of Integer, attrs["estimated_loss"]
  end

  def test_money_above_the_safe_integer_range_is_out_of_range
    assert_equal [["estimated_loss", "out_of_range"]], errors_for({ "estimated_loss" => 2**53 })
  end

  def test_enum_and_boolean_codes
    assert_equal [["line_of_business", "inclusion"]], errors_for({ "line_of_business" => "boat" })
    assert_equal [["cat_event", "not_a_boolean"]], errors_for({ "cat_event" => "yes" })
    %w[Texas ZZ tx].each { |s| assert_equal [["loss_state", "inclusion"]], errors_for({ "loss_state" => s }) }
  end

  def test_missing_required_fields
    %w[claim_number line_of_business estimated_loss loss_state].each do |field|
      assert_equal [[field, "missing"]], errors_for(without: [field])
    end
  end

  def test_claim_number_shape
    ["", "   ", "A" * 33, 42, "CLM/1", " CLM-1", "CLM-1 ", "\tCLM-1", "CLM-1 ", "stats"].each do |bad|
      assert_equal [["claim_number", "invalid_value"]], errors_for({ "claim_number" => bad }), bad.inspect
    end
    ["A" * 32, "CLM 1", "Stats", "stats-1"].each do |good|
      assert_empty errors_for({ "claim_number" => good }), good.inspect
    end
  end

  def test_unknown_fields_are_rejected
    assert_equal [["vehicle_val", "unknown_field"]], errors_for({ "vehicle_val" => 120_000 })
  end

  def test_all_errors_are_reported_together_in_field_order
    assert_equal [%w[line_of_business inclusion], %w[estimated_loss invalid_value], %w[extra unknown_field]],
                 errors_for({ "extra" => 1, "estimated_loss" => "lots", "line_of_business" => "boat" })
  end

  def test_body_must_be_an_object
    [[], "claim", 1, nil].each do |body|
      assert_equal [["$", "invalid_value"]], Dispatch::ClaimInput.validate(body).last.map(&:to_a)
    end
  end
end
