# Per-token fixed-window rate limit (Q48). The window starts at the token's first request
# in it; a rejected request neither counts nor extends the window. In-process state: one
# app process per deployment in v1.
class RateLimiter
  Decision = Struct.new(:allowed, :retry_after) do
    def allowed?
      allowed
    end
  end

  Window = Struct.new(:started_at, :count)

  attr_reader :limit, :window_seconds

  def initialize(limit:, window_seconds:, clock: Clock)
    raise ArgumentError, "limit must be a positive integer" unless limit.is_a?(Integer) && limit.positive?
    raise ArgumentError, "window must be a positive integer" unless window_seconds.is_a?(Integer) && window_seconds.positive?

    @limit = limit
    @window_seconds = window_seconds
    @clock = clock
    @windows = {}
    @mutex = Mutex.new
  end

  # Counts the request against `key` if it is allowed. retry_after is the whole seconds
  # until the window resets (never 0).
  def check(key)
    now = @clock.now
    @mutex.synchronize do
      window = @windows[key]
      window = @windows[key] = Window.new(now, 0) if window.nil? || now >= window.started_at + window_seconds
      if window.count >= limit
        Decision.new(false, [(window.started_at + window_seconds - now).ceil, 1].max)
      else
        window.count += 1
        Decision.new(true, nil)
      end
    end
  end
end
