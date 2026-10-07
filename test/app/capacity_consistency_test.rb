require_relative "../app_helper"

# QA consistency check (Q18, Q19, Q37, Q47): after a burst of concurrent dispatches and
# re-dispatches, including two re-dispatches of the same claim racing each other, every
# adjuster's stored open_claims equals the number of claims actually assigned to them,
# nobody is over capacity, and each claim's event sequence is 1..dispatch_count with no
# gaps and agrees with the claim's latest result.
#
# Real threads on their own connections and real commits, so this test is not wrapped in
# a rolled-back transaction; it cleans the tables itself before and after.
class CapacityConsistencyTest < ActiveSupport::TestCase
  include AppTestHelpers

  self.use_transactional_tests = false

  # Holds each thread's FIRST candidate selection until every thread has selected, so all
  # of them race for the same snapshot (the same idea as features/support/race.rb).
  class FirstSelectionBarrier
    def initialize(parties, timeout_seconds: 20)
      @parties = parties
      @timeout = timeout_seconds
      @arrived = 0
      @mutex = Mutex.new
      @cv = ConditionVariable.new
    end

    def wait
      return if Thread.current[:qa_seam_passed]

      Thread.current[:qa_seam_passed] = true
      @mutex.synchronize do
        @arrived += 1
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        @cv.broadcast if @arrived >= @parties
        while @arrived < @parties
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "only #{@arrived} of #{@parties} threads reached the seam" if remaining <= 0

          @cv.wait(@mutex, remaining)
        end
      end
    end
  end

  def setup
    wipe
    super
  end

  def teardown
    super
    wipe
  end

  def wipe
    DispatchEvent.delete_all
    Claim.delete_all
    Adjuster.update_all(open_claims: 0)
  end

  # Runs each job on its own thread and connection, all released together at the seam.
  def race(jobs)
    barrier = FirstSelectionBarrier.new(jobs.size)
    ClaimDispatcher.after_candidate_selection = ->(_claim, _result) { barrier.wait }
    threads = jobs.map do |job|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection { job.call }
      end
    end
    threads.map(&:value)
  ensure
    ClaimDispatcher.after_candidate_selection = nil
  end

  def assert_capacity_consistent(stage)
    Adjuster.order(:id).each do |adjuster|
      held = Claim.where(adjuster_id: adjuster.id).count
      assert_equal held, adjuster.open_claims,
                   "#{stage}: #{adjuster.id} has open_claims=#{adjuster.open_claims} but #{held} claims assigned to it"
      assert_operator adjuster.open_claims, :<=, adjuster.capacity, "#{stage}: #{adjuster.id} is over capacity"
    end
    assert_empty CapacityAudit.new.violations, stage
    Claim.includes(:dispatch_events).find_each do |claim|
      assert_equal (1..claim.dispatch_count).to_a, claim.dispatch_events.map(&:sequence),
                   "#{stage}: #{claim.claim_number} event sequence has a gap or duplicate"
      latest = claim.dispatch_events.last
      assert_equal [claim.status, claim.adjuster_id, claim.queue], [latest.status, latest.adjuster_id, latest.queue],
                   "#{stage}: #{claim.claim_number} disagrees with its latest event"
      assert_equal claim.status == "assigned", !claim.adjuster_id.nil?, "#{stage}: #{claim.claim_number} status/adjuster"
    end
  end

  def mixed_claims
    Array.new(8) { |i| claim_attrs("TX-#{i}") } +                                     # auto_standard pool, 6 slots
      Array.new(4) { |i| luxury_ca("LUX-#{i}") } +                                    # one 2-slot adjuster
      Array.new(4) { |i| claim_attrs("PR-#{i}", lob: "property", vehicle: nil, state: "TX", cat: true, loss: 80_000) }
  end

  test "open_claims matches assigned claims after concurrent dispatches and racing re-dispatches" do
    race(mixed_claims.map { |attrs| -> { ClaimDispatcher.new.create(attrs) } })
    assert_capacity_consistent("after 16 concurrent creates")

    # Move luxury claims elsewhere, so re-dispatch really releases and takes different slots.
    rules = base_rules
    rules["rules"].find { |r| r["id"] == "luxury_auto" }["conditions"][1]["value"] = 150_000
    DispatchSettings.rules = Dispatch::RulesConfig.from_h(rules)

    # Ten claims (luxury ones included), each re-dispatched by TWO threads at once: 20 threads racing,
    # within the test pool of 25 connections.
    ids = Claim.order(:id).pluck(:id).last(10)
    race((ids + ids).map { |id| -> { ClaimDispatcher.new.redispatch(Claim.find(id)) } })
    assert_capacity_consistent("after paired concurrent re-dispatches")
    assert_equal [3] * ids.size, Claim.where(id: ids).order(:id).pluck(:dispatch_count), "each claim was dispatched once and re-dispatched twice"

    # Interleaved creates and re-dispatches.
    more = Array.new(6) { |i| claim_attrs("TX-B#{i}") }.map { |attrs| -> { ClaimDispatcher.new.create(attrs) } }
    again = ids.first(10).map { |id| -> { ClaimDispatcher.new.redispatch(Claim.find(id)) } }
    race(more + again)
    assert_capacity_consistent("after interleaved creates and re-dispatches")
    assert_equal Claim.sum(:dispatch_count), DispatchEvent.count
  end
end
