# Creates and re-dispatches claims: the engine decides, this class makes the decision
# stick in the database without ever over-assigning an adjuster (Q37), then sends the
# webhook after commit (Q24).
#
# Every attempt is:
#   1. Selection: a plain read of the roster and Engine#decide, with no transaction open.
#   2. The race seam (tests only, see below).
#   3. One short write transaction: the conditional UPDATE that claims the slot, plus the
#      claim and dispatch-event writes. If the UPDATE changes 0 rows another request took
#      the slot, so the transaction rolls back and step 1 runs again, afresh, excluding
#      that adjuster. A claim is left unassigned only when every qualified adjuster is full.
#
# The first statement of each write transaction is a write, so SQLite takes the write lock
# (waiting out the busy timeout) before reading anything; a read-to-write upgrade, which
# fails with SQLITE_BUSY_SNAPSHOT under WAL, never happens.
class ClaimDispatcher
  class DuplicateClaimNumber < StandardError; end

  # Raised inside a write transaction when a concurrent re-dispatch of the same claim
  # committed first. The transaction rolls back and the re-dispatch starts over.
  class StaleClaim < StandardError; end

  MAX_STALE_RETRIES = 10

  class << self
    # Test-only race seam (STEP_GLOSSARY.md section 9): called as hook.call(claim, result)
    # after every candidate selection and before the write transaction, with no transaction
    # open. Nil in production; setting it outside the test environment raises.
    def after_candidate_selection=(hook)
      raise ArgumentError, "the race seam is test-only (Rails.env is #{Rails.env})" if hook && !Rails.env.test?

      @after_candidate_selection = hook
    end

    def after_candidate_selection
      Rails.env.test? ? @after_candidate_selection : nil
    end
  end

  def initialize(rules: DispatchSettings.rules, notifier: WebhookNotifier.new, clock: Clock)
    @engine = Dispatch::Engine.new(rules)
    @notifier = notifier
    @clock = clock
  end

  # Creates and dispatches a claim from validated attributes (Dispatch::ClaimInput).
  # Returns the persisted Claim. Raises DuplicateClaimNumber.
  def create(attributes)
    claim = Dispatch::Claim.from_h(attributes)
    # The unique index is the real guard; this read just avoids a pointless dispatch.
    raise DuplicateClaimNumber, claim.claim_number if Claim.exists?(claim_number: claim.claim_number)

    record = nil
    event = decide_and_write(claim) do |result|
      record = Claim.create!(claim.to_h.merge(Claim.result_columns(result)).merge(dispatch_count: 1,
                                                                                 created_at: @clock.now))
      create_event(record, claim, result, sequence: 1)
    end
    deliver(event)
    record.reload
  rescue ActiveRecord::RecordNotUnique
    raise DuplicateClaimNumber, claim.claim_number
  end

  # Re-dispatch (Q19): releases the current assignment, routes again with the current
  # rules and roster, appends to the history and sends a new event, even if nothing changed.
  # The release and the new assignment commit together, so the claim is never lost between them.
  def redispatch(record)
    MAX_STALE_RETRIES.times do
      record.reload
      previous = record.adjuster_id
      sequence = record.dispatch_count + 1
      claim = record.to_engine
      begin
        event = decide_and_write(claim, releasing: previous) do |result|
          # Optimistic check: a concurrent re-dispatch of this claim would double-release.
          moved = Claim.where(id: record.id, dispatch_count: record.dispatch_count)
                       .update_all(Claim.result_columns(result).merge(dispatch_count: sequence, updated_at: @clock.now))
          raise StaleClaim if moved.zero?

          create_event(record, claim, result, sequence: sequence)
        end
        deliver(event)
        return record.reload
      rescue StaleClaim
        next
      end
    end
    raise StaleClaim, "claim #{record.claim_number} kept changing during re-dispatch"
  end

  private

  # Runs selection -> seam -> write transaction until the decision commits. The block
  # writes the claim and its event for `result` and returns the event; it runs inside the
  # transaction, after the slot is claimed (and the previous one released).
  def decide_and_write(claim, releasing: nil)
    excluded = []
    loop do
      result = @engine.decide(claim, Adjuster.engine_roster(releasing: releasing), exclude: excluded)
      self.class.after_candidate_selection&.call(claim, result)

      event = ApplicationRecord.transaction(requires_new: true) do
        written = yield(result)
        Adjuster.release_slot(releasing) if releasing
        raise ActiveRecord::Rollback if result.assigned? && !Adjuster.take_slot(result.adjuster_id)

        written
      end
      return event if event

      # Lost the race for that slot: it is full now. Re-select among the rest.
      Rails.logger.info("dispatch #{claim.claim_number}: lost the race for #{result.adjuster_id}; re-selecting")
      excluded << result.adjuster_id
    end
  end

  def create_event(record, claim, result, sequence:)
    event_id = Dispatch::Webhook.generate_event_id
    payload = Dispatch::Webhook.payload(claim, result, event_id: event_id, occurred_at: @clock.now, sequence: sequence)
    record.dispatch_events.create!(
      sequence: sequence, event_id: event_id, event: payload["event"], occurred_at: Time.iso8601(payload["occurred_at"]),
      payload: JSON.generate(payload), **Claim.result_columns(result)
    )
  end

  # After commit. Never raises (WebhookNotifier records and logs failures).
  def deliver(event)
    @notifier.deliver(event)
  end
end
