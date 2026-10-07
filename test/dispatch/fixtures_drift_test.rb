require_relative "../test_helper"

# Review L10: the unit-test fixtures in test_helper.rb are hand copies of the gate
# feature's Background. Fail if they drift from the spec tables.
class FixturesDriftTest < Minitest::Test
  def test_base_rules_match_the_background
    assert_equal GateBackground.rules, DispatchFixtures::BASE_RULES
  end

  def test_roster_matches_the_background
    assert_equal GateBackground.roster, DispatchFixtures::ROSTER
  end

  def test_replay_claims_match_the_background
    expected = GateBackground.replay_claims.map { |h| { "vehicle_value" => nil }.merge(h) }
    assert_equal expected, DispatchFixtures::REPLAY_CLAIMS.map(&:to_h)
  end

  def test_the_parser_reads_every_table_row
    assert_equal [7, 8, 10], [GateBackground.rules["rules"].size, GateBackground.roster.size, GateBackground.replay_claims.size]
  end
end
