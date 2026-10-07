require_relative "../app_helper"

# BUG-022: re-seeding refreshes adjusters from config/adjusters.json but never resets the
# open_claims counter of an adjuster that already holds claims.
class SeedsTest < ActiveSupport::TestCase
  include AppTestHelpers

  def seed!
    capture_io { load Rails.root.join("db/seeds.rb").to_s }
  end

  test "re-seeding keeps the counters of adjusters that hold claims" do
    3.times { |i| ClaimDispatcher.new.create(claim_attrs("CLM-S#{i}", state: "TX")) }
    before = Adjuster.order(:id).pluck(:id, :open_claims).to_h
    assert_equal 3, before.values.sum

    seed!

    after = Adjuster.where(id: before.keys).order(:id).pluck(:id, :open_claims).to_h
    assert_equal before, after
  end

  test "re-seeding refreshes every other field from the file" do
    Adjuster.where(id: "ADJ-001").update_all(capacity: 99, name: "Renamed", active: false, open_claims: 2)

    seed!

    adjuster = Adjuster.find("ADJ-001")
    file = DispatchSettings.roster.adjusters.find { |a| a.id == "ADJ-001" }
    assert_equal [file.capacity, file.name, file.active, 2], [adjuster.capacity, adjuster.name, adjuster.active, adjuster.open_claims]
  end

  test "an adjuster new to the table starts at the file's baseline" do
    Adjuster.where(id: "ADJ-025").delete_all

    seed!

    file = DispatchSettings.roster.adjusters.find { |a| a.id == "ADJ-025" }
    assert_equal file.open_claims, Adjuster.find("ADJ-025").open_claims
  end
end
