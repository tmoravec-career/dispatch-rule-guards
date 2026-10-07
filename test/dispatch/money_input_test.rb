require_relative "../test_helper"

# Q50: the UI's money fields take formatted text and store whole dollars.
class MoneyInputTest < Minitest::Test
  def parse(text)
    Dispatch::MoneyInput.parse(text)
  end

  def test_accepts_plain_and_formatted_whole_dollars
    {
      "12000" => 12_000, "$12,000" => 12_000, "12,000.00" => 12_000, "$12,000.00" => 12_000,
      "12000.00" => 12_000, "$120,000" => 120_000, "1,234,567" => 1_234_567, "0" => 0, "$0.00" => 0,
      "  12,000  " => 12_000, "12000.0" => 12_000, "999" => 999, "$1,000" => 1000
    }.each do |text, dollars|
      assert_equal [dollars, nil], parse(text), text.inspect
    end
  end

  def test_blank_is_no_value
    ["", "   ", nil].each { |text| assert_equal [nil, nil], parse(text), text.inspect }
  end

  def test_non_zero_cents_are_not_whole_dollars
    %w[12,000.50 $12,000.5 12000.01 0.99].each do |text|
      assert_equal [nil, "not_an_integer"], parse(text), text
    end
  end

  def test_negatives_are_out_of_range
    %w[-100 -$500 $-500 -12,000.00].each { |text| assert_equal [nil, "out_of_range"], parse(text), text }
  end

  def test_junk_is_invalid
    ["twelve", "12O00", "1.2e5", "1e3", "12,00", "1,2000", "12,000,00", ",000", "$", "$$12", "12 000", "0x10",
     "12.000", "12.", ".50", "+12", "12000$", "١٢٣"].each do |text|
      assert_equal [nil, "invalid_value"], parse(text), text
    end
  end

  def test_amounts_beyond_json_safe_integers_are_out_of_range
    assert_equal [Dispatch::ClaimInput::MAX_MONEY, nil], parse(Dispatch::ClaimInput::MAX_MONEY.to_s)
    assert_equal [nil, "out_of_range"], parse((Dispatch::ClaimInput::MAX_MONEY + 1).to_s)
  end
end
