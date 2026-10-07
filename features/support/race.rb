# The @concurrency harness (STEP_GLOSSARY.md section 9, Q37).
#
# ClaimDispatcher's test-only seam fires after each candidate selection, before the write
# transaction. The hook installed here parks each thread's FIRST selection at a barrier
# until all N threads have selected, so they all race for the same snapshot and the
# losing-UPDATE / re-select path runs every time, not by luck. Re-selections pass straight
# through. Waiting is a condition variable with a deadline, never a timed pause, and a
# stuck barrier fails loudly instead of hanging.
class RaceBarrier
  class Timeout < StandardError; end

  def initialize(parties, timeout_seconds: 10)
    @parties = parties
    @timeout_seconds = timeout_seconds
    @arrived = 0
    @mutex = Mutex.new
    @all_arrived = ConditionVariable.new
  end

  def wait
    @mutex.synchronize do
      @arrived += 1
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds
      @all_arrived.broadcast if @arrived == @parties
      while @arrived < @parties
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          raise Timeout, "only #{@arrived} of #{@parties} threads reached the race seam within #{@timeout_seconds}s"
        end

        @all_arrived.wait(@mutex, remaining)
      end
    end
  end
end

module RaceWorld
  # Dispatches `copies` claim hashes from one thread each, through the real service and DB,
  # each thread on its own connection. Returns the Claims; re-raises any thread's error.
  def dispatch_concurrently(claim_hashes)
    pool = ActiveRecord::Base.connection_pool
    needed = claim_hashes.size + 1
    assert pool.size >= needed,
           "the connection pool holds #{pool.size} connections; #{claim_hashes.size} threads plus the main thread need #{needed}"

    barrier = RaceBarrier.new(claim_hashes.size)
    ClaimDispatcher.after_candidate_selection = lambda do |_claim, _result|
      if ActiveRecord::Base.connection_pool.active_connection&.transaction_open?
        raise "a transaction is open at the race seam: selection must be a plain read (Q37)"
      end
      next if Thread.current[:race_seam_passed]

      Thread.current[:race_seam_passed] = true
      barrier.wait
    end

    threads = claim_hashes.map do |hash|
      Thread.new do
        Thread.current.report_on_exception = false
        pool.with_connection do
          attributes, errors = Dispatch::ClaimInput.validate(hash)
          raise "invalid claim #{hash.inspect}: #{errors.map(&:to_a)}" unless errors.empty?

          ClaimDispatcher.new.create(attributes)
        end
      end
    end
    threads.map(&:value)
  ensure
    ClaimDispatcher.after_candidate_selection = nil
  end
end

World(RaceWorld)
