# The app's one source of time (STEP_GLOSSARY.md section 2a). Tests freeze and advance
# it, so time-dependent behaviour (rate-limit windows, occurred_at) never needs a sleep.
module Clock
  @frozen_at = nil
  @mutex = Mutex.new

  class << self
    def now
      @frozen_at || Time.now.utc
    end

    def freeze_at(time)
      @mutex.synchronize { @frozen_at = time.utc }
    end

    def advance(seconds)
      @mutex.synchronize do
        raise "the clock is not frozen" unless @frozen_at

        @frozen_at += seconds
      end
    end

    def unfreeze
      @mutex.synchronize { @frozen_at = nil }
    end
  end
end
