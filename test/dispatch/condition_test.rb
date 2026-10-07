require_relative "../test_helper"

# Operator semantics (Q3, Q4, Q8).
class ConditionTest < Minitest::Test
  def cond(field, op, value)
    Dispatch::Condition.new(field: field, op: op, value: value)
  end

  def claim(**attrs)
    Dispatch::Claim.new(**{ claim_number: "C", line_of_business: "auto", estimated_loss: 10_000,
                            vehicle_value: nil, cat_event: false, loss_state: "TX" }.merge(attrs))
  end

  def test_numeric_operators_at_value_minus_one_value_and_plus_one
    expectations = {
      "gt" => [false, false, true],
      "gte" => [false, true, true],
      "lt" => [true, false, false],
      "lte" => [true, true, false]
    }
    expectations.each do |op, expected|
      actual = [49_999, 50_000, 50_001].map { |loss| cond("estimated_loss", op, 50_000).matches?(claim(estimated_loss: loss)) }
      assert_equal expected, actual, op
    end
  end

  def test_float_threshold
    assert cond("estimated_loss", "gt", 100.5).matches?(claim(estimated_loss: 101))
    refute cond("estimated_loss", "gt", 100.5).matches?(claim(estimated_loss: 100))
  end

  def test_eq_compares_booleans_exactly
    assert cond("cat_event", "eq", true).matches?(claim(cat_event: true))
    refute cond("cat_event", "eq", true).matches?(claim(cat_event: false))
    assert cond("cat_event", "eq", false).matches?(claim(cat_event: false))
  end

  def test_eq_is_case_sensitive
    assert cond("loss_state", "eq", "TX").matches?(claim(loss_state: "TX"))
    refute cond("loss_state", "eq", "tx").matches?(claim(loss_state: "TX"))
  end

  def test_in_matches_any_listed_value
    c = cond("loss_state", "in", %w[TX FL LA])
    assert c.matches?(claim(loss_state: "LA"))
    refute c.matches?(claim(loss_state: "GA"))
  end

  def test_absent_field_does_not_match_and_does_not_error
    refute cond("vehicle_value", "gte", 100_000).matches?(claim(vehicle_value: nil))
    refute cond("vehicle_value", "lt", 100_000).matches?(claim(vehicle_value: nil))
    refute cond("vehicle_value", "eq", 0).matches?(claim(vehicle_value: nil))
  end

  def test_numeric_operator_on_non_numeric_claim_value_does_not_match
    refute cond("loss_state", "gt", 5).matches?(claim(loss_state: "TX"))
    refute cond("cat_event", "gte", 0).matches?(claim(cat_event: true))
  end

  def test_to_s_uses_table_clause_syntax
    assert_equal "loss_state in TX,FL,LA", cond("loss_state", "in", %w[TX FL LA]).to_s
    assert_equal "estimated_loss gte 50000", cond("estimated_loss", "gte", 50_000).to_s
  end
end
