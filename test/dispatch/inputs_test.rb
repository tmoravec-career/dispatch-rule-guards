require_relative "../test_helper"

# Loading the roster and claims files the gate replays (Q1 claim fields).
class InputsTest < Minitest::Test
  def adjuster(overrides = {})
    { "id" => "ADJ-001", "name" => "A", "active" => true, "licensed_states" => ["TX"], "skills" => ["auto"],
      "capacity" => 3, "open_claims" => 0 }.merge(overrides)
  end

  def roster_errors(hash)
    Dispatch::Roster.from_h(hash)
    flunk "expected roster to be rejected"
  rescue Dispatch::ConfigError => e
    e.errors.map { |err| [err.code, err.path] }.sort
  end

  def test_roster_loads
    roster = DispatchFixtures.roster
    assert_equal 8, roster.adjusters.size
    assert_equal %w[TX FL], roster.find("ADJ-001").licensed_states
    refute roster.find("ADJ-007").active
  end

  def test_roster_copy_is_independent
    roster = DispatchFixtures.roster
    copy = roster.copy
    roster.assign!("ADJ-001")
    assert_equal 0, copy.find("ADJ-001").open_claims
  end

  def test_roster_validation
    hash = { "adjusters" => [
      adjuster("capacity" => -1, "extra" => 1),
      adjuster("active" => "yes", "open_claims" => 5),
      adjuster("id" => "ADJ-002", "licensed_states" => "TX").tap { |a| a.delete("name") }
    ] }
    assert_equal [["duplicate_adjuster_id", "adjusters[1].id"],
                  ["invalid_value", "adjusters[0].capacity"],
                  ["invalid_value", "adjusters[1].active"],
                  ["invalid_value", "adjusters[1].open_claims"],
                  ["invalid_value", "adjusters[2].licensed_states"],
                  ["missing_field", "adjusters[2].name"],
                  ["unknown_field", "adjusters[0].extra"]], roster_errors(hash)
  end

  # Q55 G5: building a roster in code validates like the loader.
  def test_roster_new_validates
    over = Dispatch::Adjuster.from_h(adjuster("open_claims" => 4))
    error = assert_raises(Dispatch::ConfigError) { Dispatch::Roster.new([over]) }
    assert_equal [["invalid_value", "adjusters[0].open_claims"]], error.errors.map { |e| [e.code, e.path] }

    twins = [Dispatch::Adjuster.from_h(adjuster), Dispatch::Adjuster.from_h(adjuster)]
    error = assert_raises(Dispatch::ConfigError) { Dispatch::Roster.new(twins) }
    assert_equal [["duplicate_adjuster_id", "adjusters[1].id"]], error.errors.map { |e| [e.code, e.path] }

    assert_raises(Dispatch::ConfigError) { Dispatch::Roster.new([adjuster]) }
  end

  def test_roster_update_validates_and_changes_nothing_on_error
    roster = DispatchFixtures.roster
    [[{ capacity: -1 }, "invalid_value", "adjusters[0].capacity"],
     [{ open_claims: 4 }, "invalid_value", "adjusters[0].open_claims"],
     [{ active: "no" }, "invalid_value", "adjusters[0].active"],
     [{ enforce_licensing: false }, "unknown_field", "adjusters[0].enforce_licensing"],
     [{ id: "ADJ-002" }, "duplicate_adjuster_id", "adjusters[1].id"]].each do |changes, code, path|
      error = assert_raises(Dispatch::ConfigError, changes.inspect) { roster.update("ADJ-001", **changes) }
      assert_includes error.errors.map { |e| [e.code, e.path] }, [code, path], changes.inspect
    end
    assert_equal DispatchFixtures::ROSTER, roster.to_h["adjusters"]
    roster.update("ADJ-001", active: false)
    refute roster.find("ADJ-001").active
  end

  # QA L3: setting the counter directly can't exceed capacity either.
  def test_set_open_claims_validates_and_changes_nothing_on_error
    roster = DispatchFixtures.roster
    [[99, "invalid_value"], [-1, "invalid_value"], [1.5, "invalid_value"]].each do |count, code|
      error = assert_raises(Dispatch::ConfigError, count.inspect) { roster.set_open_claims("ADJ-004", count) }
      assert_equal [[code, "adjusters[3].open_claims"]], error.errors.map { |e| [e.code, e.path] }
    end
    assert_equal 0, roster.find("ADJ-004").open_claims
    roster.set_open_claims("ADJ-004", 2)
    assert_equal 2, roster.find("ADJ-004").open_claims
  end

  def test_roster_unknown_id
    assert_raises(KeyError) { DispatchFixtures.roster.find("ADJ-999") }
  end

  def claim_errors(array)
    Dispatch::Claim.load_all(array)
    flunk "expected claims to be rejected"
  rescue Dispatch::ConfigError => e
    e.errors.map { |err| [err.code, err.path] }.sort
  end

  def test_claims_load_with_absent_optional_fields
    claims = Dispatch::Claim.load_all([
      { "claim_number" => "CLM-1", "line_of_business" => "property", "estimated_loss" => 10, "loss_state" => "TX" }
    ])
    assert_nil claims.first.vehicle_value
    assert_equal false, claims.first.cat_event
  end

  def test_unvalidated_from_h_treats_absent_keys_as_absent_fields
    claim = Dispatch::Claim.from_h("claim_number" => "C", "line_of_business" => "auto", "loss_state" => "TX")
    assert_nil claim.estimated_loss
    assert_nil claim.vehicle_value
    assert_equal false, claim.cat_event
  end

  def test_claim_validation
    errors = claim_errors([
      { "claim_number" => "CLM-1", "line_of_business" => "boat", "estimated_loss" => 1.5, "loss_state" => "tx" },
      { "claim_number" => "CLM-1", "line_of_business" => "auto", "estimated_loss" => -1, "vehicle_value" => "9",
        "cat_event" => "no", "loss_state" => "TX", "colour" => "red" },
      { "line_of_business" => "auto", "loss_state" => "TX" }
    ])
    assert_equal [["duplicate_claim_number", "[1].claim_number"],
                  ["invalid_value", "[0].estimated_loss"],
                  ["invalid_value", "[0].line_of_business"],
                  ["invalid_value", "[0].loss_state"],
                  ["invalid_value", "[1].cat_event"],
                  ["invalid_value", "[1].estimated_loss"],
                  ["invalid_value", "[1].vehicle_value"],
                  ["missing_field", "[2].claim_number"],
                  ["missing_field", "[2].estimated_loss"],
                  ["unknown_field", "[1].colour"]], errors
  end

  # Q55: values that parse to Infinity are invalid_value in claims and rosters.
  def test_non_finite_numbers_in_claims_and_roster
    claims = JSON.parse('[{"claim_number":"C","line_of_business":"auto","estimated_loss":1e400,' \
                        '"vehicle_value":-1e400,"loss_state":"TX"}]')
    assert_equal [["invalid_value", "[0].estimated_loss"], ["invalid_value", "[0].vehicle_value"]], claim_errors(claims)
    roster = JSON.parse('{"adjusters":[{"id":"A","name":"A","active":true,"licensed_states":["TX"],"skills":[],' \
                        '"capacity":1e400,"open_claims":0}]}')
    assert_equal [["invalid_value", "adjusters[0].capacity"]], roster_errors(roster)
  end

  def test_claims_must_be_an_array
    assert_equal [["invalid_value", "$"]], claim_errors({ "claims" => [] })
  end

  def test_claim_number_length
    assert_equal [["invalid_value", "[0].claim_number"]],
                 claim_errors([{ "claim_number" => "X" * 33, "line_of_business" => "auto", "estimated_loss" => 1, "loss_state" => "TX" }])
  end
end
