require_relative "../app_helper"

# The web form's input handling (Q41, Q50): formatted money, blank fields, the checkbox,
# and that nothing is dispatched unless every field is valid.
class ClaimFormTest < ActiveSupport::TestCase
  include AppTestHelpers

  def form(overrides = {})
    ClaimForm.new({ "claim_number" => "CLM-F1", "line_of_business" => "auto", "estimated_loss" => "$12,000.00",
                    "vehicle_value" => "120,000", "cat_event" => "0", "loss_state" => "CA" }.merge(overrides))
  end

  test "formatted money is stored as whole dollars and the claim is dispatched" do
    f = form
    assert f.submit, f.errors.inspect
    claim = Claim.find_by!(claim_number: "CLM-F1")
    assert_equal [12_000, 120_000, false], [claim.estimated_loss, claim.vehicle_value, claim.cat_event]
    assert_equal "luxury_auto", claim.queue
    assert_equal 1, claim.dispatch_events.count
  end

  test "a blank vehicle value is absent and a checked box is a CAT event" do
    f = form("claim_number" => "CLM-F2", "line_of_business" => "property", "estimated_loss" => "60000",
             "vehicle_value" => "  ", "cat_event" => "1", "loss_state" => "TX")
    assert f.submit, f.errors.inspect
    claim = f.claim
    assert_nil claim.vehicle_value
    assert claim.cat_event
  end

  test "each invalid field gets its own code and nothing is persisted" do
    f = form("claim_number" => "", "line_of_business" => "boat", "estimated_loss" => "12,000.50",
             "vehicle_value" => "1.2e5", "loss_state" => "")
    refute f.submit
    assert_equal({ "claim_number" => "missing", "line_of_business" => "inclusion", "estimated_loss" => "not_an_integer",
                   "vehicle_value" => "invalid_value", "loss_state" => "missing" }, f.errors)
    assert_equal 0, Claim.count
  end

  test "an unparseable estimated loss is reported as such, not as missing" do
    f = form("estimated_loss" => "twelve")
    refute f.submit
    assert_equal({ "estimated_loss" => "invalid_value" }, f.errors)
  end

  test "a negative amount is out of range" do
    f = form("estimated_loss" => "-$500")
    refute f.submit
    assert_equal({ "estimated_loss" => "out_of_range" }, f.errors)
  end

  test "a duplicate claim number is a field error, not an exception" do
    assert form.submit
    again = form
    refute again.submit
    assert_equal({ "claim_number" => "duplicate_claim_number" }, again.errors)
  end

  test "the claim number is trimmed, so edge whitespace is not an error" do
    f = form("claim_number" => "  CLM-F3 ")
    assert f.submit, f.errors.inspect
    assert_equal "CLM-F3", f.claim.claim_number
  end
end
