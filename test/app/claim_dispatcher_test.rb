require_relative "../app_helper"

# ClaimDispatcher: atomic capacity (Q37), re-dispatch (Q18, Q19) and the race seam.
class ClaimDispatcherTest < ActiveSupport::TestCase
  include AppTestHelpers

  def dispatcher
    ClaimDispatcher.new
  end

  test "create assigns, takes a slot and records event 1" do
    claim = dispatcher.create(luxury_ca("C-1"))
    assert_equal ["assigned", "luxury_auto", "ADJ-004"], [claim.status, claim.queue, claim.adjuster_id]
    assert_equal 1, open_claims("ADJ-004")
    event = claim.dispatch_events.sole
    assert_equal [1, "claim.assigned", "not_configured"], [event.sequence, event.event, event.webhook_status]
    assert_equal event.event_id, JSON.parse(event.payload)["event_id"]
  end

  test "a duplicate claim number is refused and changes nothing" do
    dispatcher.create(claim_attrs("C-1"))
    assert_raises(ClaimDispatcher::DuplicateClaimNumber) { dispatcher.create(claim_attrs("C-1")) }
    assert_equal 1, open_claims("ADJ-001")
    assert_equal 1, DispatchEvent.count
  end

  # The seam lets this single-threaded test lose a race on purpose: the hook fills the
  # chosen adjuster between selection and the conditional UPDATE, as a concurrent request would.
  test "losing the race for a slot re-selects among the remaining qualified adjusters" do
    selections = []
    ClaimDispatcher.after_candidate_selection = lambda do |_claim, result|
      selections << result.adjuster_id
      Adjuster.where(id: "ADJ-001").update_all("open_claims = capacity") if selections.size == 1
    end
    claim = dispatcher.create(claim_attrs("C-1"))
    assert_equal %w[ADJ-001 ADJ-002], selections
    assert_equal "ADJ-002", claim.adjuster_id
    assert_equal [3, 1], [open_claims("ADJ-001"), open_claims("ADJ-002")]
  end

  test "a lost race leaves the claim unassigned only when every qualified adjuster is full" do
    ClaimDispatcher.after_candidate_selection = lambda do |_claim, result|
      Adjuster.where(id: result.adjuster_id).update_all("open_claims = capacity") if result.adjuster_id
    end
    claim = dispatcher.create(claim_attrs("C-1"))
    assert_equal ["unassigned", nil, "qualified_adjusters_at_capacity"],
                 [claim.status, claim.adjuster_id, claim.reason_code]
    assert_equal [3, 3], [open_claims("ADJ-001"), open_claims("ADJ-002")]
  end

  test "the seam runs with no transaction open beyond the test's own" do
    baseline = Claim.connection.open_transactions
    open = nil
    ClaimDispatcher.after_candidate_selection = ->(_claim, _result) { open = Claim.connection.open_transactions }
    dispatcher.create(claim_attrs("C-1"))
    assert_equal baseline, open
  end

  test "the race seam is refused outside the test environment" do
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      error = assert_raises(ArgumentError) { ClaimDispatcher.after_candidate_selection = ->(*) {} }
      assert_match(/test-only/, error.message)
      assert_nil ClaimDispatcher.after_candidate_selection
    end
  end

  test "re-dispatch releases the previous slot before choosing, so a full adjuster keeps the claim" do
    dispatcher.create(luxury_ca("C-1"))
    dispatcher.create(luxury_ca("C-2"))
    assert_equal 2, open_claims("ADJ-004") # at capacity, and one slot is C-1's
    claim = dispatcher.redispatch(Claim.find_by!(claim_number: "C-1"))
    assert_equal "ADJ-004", claim.adjuster_id
    assert_equal 2, open_claims("ADJ-004")
    assert_equal [1, 2], claim.dispatch_events.map(&:sequence)
  end

  test "re-dispatch moves the slot when the current rules route elsewhere" do
    dispatcher.create(luxury_ca("C-1"))
    rules = base_rules
    rules["rules"].find { |r| r["id"] == "luxury_auto" }["conditions"][1]["value"] = 150_000
    DispatchSettings.rules = Dispatch::RulesConfig.from_h(rules)
    claim = dispatcher.redispatch(Claim.find_by!(claim_number: "C-1"))
    assert_equal ["auto_standard", "ADJ-005"], [claim.queue, claim.adjuster_id]
    assert_equal [0, 1], [open_claims("ADJ-004"), open_claims("ADJ-005")]
  end

  test "the release is guarded and never drives a counter below zero" do
    dispatcher.create(luxury_ca("C-1"))
    Adjuster.where(id: "ADJ-004").update_all(open_claims: 0, active: false)
    claim = dispatcher.redispatch(Claim.find_by!(claim_number: "C-1"))
    assert_equal "no_qualified_adjuster", claim.reason_code
    assert_equal 0, open_claims("ADJ-004")
  end

  test "a re-dispatch that loses to a concurrent re-dispatch of the same claim starts over" do
    dispatcher.create(claim_attrs("C-1"))
    record = Claim.find_by!(claim_number: "C-1")
    ClaimDispatcher.after_candidate_selection = lambda do |_claim, _result|
      ClaimDispatcher.after_candidate_selection = nil
      ClaimDispatcher.new.redispatch(Claim.find(record.id)) # commits first, as sequence 2
    end
    claim = dispatcher.redispatch(record)
    assert_equal [1, 2, 3], claim.dispatch_events.map(&:sequence)
    assert_equal 1, open_claims("ADJ-001") + open_claims("ADJ-002"), "the claim holds exactly one slot"
  end

  # Raises what the SQLite adapter raises for SQLITE_BUSY: StatementInvalid caused by BusyException.
  def raise_busy
    raise SQLite3::BusyException, "database is locked"
  rescue SQLite3::BusyException
    raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
  end

  # Fails the first `failures` slot claims with BUSY after the UPDATE ran, so a retry that
  # didn't roll back would count the slot twice.
  def with_busy_slot_claims(failures)
    calls = 0
    take_slot = Adjuster.method(:take_slot)
    Adjuster.stub(:take_slot, lambda { |id|
      calls += 1
      taken = take_slot.call(id)
      raise_busy if calls <= failures
      taken
    }) { yield }
    calls
  end

  test "every environment's transactions begin IMMEDIATE (Q57)" do
    %w[development test production].each do |env|
      config = ActiveRecord::Base.configurations.configs_for(env_name: env).first.configuration_hash
      assert_equal "immediate", config[:default_transaction_mode].to_s, env
    end
    assert_equal "immediate", Claim.connection.raw_connection.instance_variable_get(:@default_transaction_mode).to_s
  end

  test "a busy database is retried and the slot is counted once" do
    claim = nil
    calls = with_busy_slot_claims(1) { claim = dispatcher.create(claim_attrs("C-1")) }
    assert_equal 2, calls
    assert_equal ["assigned", "ADJ-001"], [claim.status, claim.adjuster_id]
    assert_equal [1, 0], [open_claims("ADJ-001"), open_claims("ADJ-002")]
    assert_equal [1, 1], [Claim.count, DispatchEvent.count]
  end

  test "after 3 busy retries the error is raised and nothing is written" do
    calls = with_busy_slot_claims(4) do
      assert_raises(ActiveRecord::StatementInvalid) { dispatcher.create(claim_attrs("C-1")) }
    end
    assert_equal 4, calls
    assert_equal [0, 0, 0], [open_claims("ADJ-001"), Claim.count, DispatchEvent.count]
  end

  test "occurred_at and created_at come from the injectable clock" do
    Clock.freeze_at(Time.utc(2026, 10, 6, 9, 0, 0))
    claim = dispatcher.create(claim_attrs("C-1"))
    Clock.advance(5)
    claim = dispatcher.redispatch(claim)
    assert_equal Time.utc(2026, 10, 6, 9), claim.created_at
    assert_equal %w[2026-10-06T09:00:00.000Z 2026-10-06T09:00:05.000Z],
                 claim.dispatch_events.map { |e| JSON.parse(e.payload)["occurred_at"] }
  end

  # BUG-023: outside test the check is on. Tests run inside a transaction, so one is open here.
  test "create refuses to run inside an open transaction and writes nothing" do
    ClaimDispatcher.stub(:refuses_outer_transaction?, true) do
      assert_raises(ClaimDispatcher::OuterTransaction) { dispatcher.create(claim_attrs("C-1")) }
    end
    assert_equal [0, 0, 0], [Claim.count, DispatchEvent.count, open_claims("ADJ-001")]
  end

  test "redispatch refuses to run inside an open transaction and changes nothing" do
    claim = dispatcher.create(claim_attrs("C-1"))
    ClaimDispatcher.stub(:refuses_outer_transaction?, true) do
      assert_raises(ClaimDispatcher::OuterTransaction) { dispatcher.redispatch(claim) }
    end
    assert_equal [1, 1], [claim.reload.dispatch_count, open_claims("ADJ-001")]
  end

  test "the outer-transaction check is off only in the test environment" do
    assert Rails.env.test?
    refute ClaimDispatcher.refuses_outer_transaction?
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert ClaimDispatcher.refuses_outer_transaction?
    end
  end
end

# The same check with no transaction open: dispatch proceeds normally.
class ClaimDispatcherNoOuterTransactionTest < ActiveSupport::TestCase
  include AppTestHelpers
  self.use_transactional_tests = false

  def teardown
    DispatchEvent.delete_all
    Claim.delete_all
    Adjuster.load_roster!(Dispatch::Roster.from_h({ "adjusters" => background_roster }), reset_open_claims: true)
    super
  end

  test "create and redispatch run when no transaction is open" do
    ClaimDispatcher.stub(:refuses_outer_transaction?, true) do
      refute ApplicationRecord.connection.transaction_open?
      claim = ClaimDispatcher.new.create(claim_attrs("C-NT"))
      assert_equal 2, ClaimDispatcher.new.redispatch(claim).dispatch_count
    end
  end
end
