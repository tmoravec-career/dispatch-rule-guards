require_relative "../test_helper"

# Seeded, realistic claim generator used by the gate when no claims file is given (Q28, Q31).
class ScenarioGeneratorTest < Minitest::Test
  def claims(seed: 42, count: 200)
    Dispatch::ScenarioGenerator.new(seed: seed, count: count).claims
  end

  def test_same_seed_same_claims
    assert_equal claims.map(&:to_h), claims.map(&:to_h)
  end

  def test_different_seed_different_claims
    refute_equal claims(seed: 42).map(&:to_h), claims(seed: 43).map(&:to_h)
  end

  def test_count_and_unique_claim_numbers
    list = claims(count: 200)
    assert_equal 200, list.size
    assert_equal 200, list.map(&:claim_number).uniq.size
  end

  def test_generated_claims_are_valid_and_varied
    list = claims
    # Round-trips through the strict claims loader.
    Dispatch::Claim.load_all(list.map(&:to_h))
    assert_equal %w[auto liability property], list.map(&:line_of_business).uniq.sort
    assert list.any?(&:cat_event)
    assert list.count { |c| c.loss_state }.positive?
    assert list.map(&:loss_state).uniq.size >= 5
    assert list.all? { |c| c.line_of_business == "auto" || c.vehicle_value.nil? }
    assert list.none? { |c| c.cat_event && c.line_of_business != "property" }
    assert list.any? { |c| c.vehicle_value && c.vehicle_value >= 100_000 }
  end
end
