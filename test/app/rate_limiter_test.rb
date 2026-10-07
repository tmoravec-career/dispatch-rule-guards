require_relative "../app_helper"

# RateLimiter (Q48): fixed window from the first request, rejects don't count, whole-second Retry-After.
class RateLimiterTest < ActiveSupport::TestCase
  FakeClock = Struct.new(:now)

  test "a fixed window per key, starting at the first request" do
    clock = FakeClock.new(Time.utc(2026, 10, 6, 9))
    limiter = RateLimiter.new(limit: 2, window_seconds: 60, clock: clock)
    assert limiter.check("a").allowed?
    clock.now += 10
    assert limiter.check("a").allowed?
    assert limiter.check("b").allowed?, "another key has its own window"
    clock.now += 0.5
    denied = limiter.check("a")
    refute denied.allowed?
    assert_equal 50, denied.retry_after, "49.5 s rounds up to whole seconds"
    clock.now += 49.5
    assert limiter.check("a").allowed?, "the window reset 60 s after the first request"
  end

  test "Retry-After is never 0" do
    clock = FakeClock.new(Time.utc(2026, 10, 6, 9))
    limiter = RateLimiter.new(limit: 1, window_seconds: 1, clock: clock)
    limiter.check("a")
    clock.now += 0.999
    assert_equal 1, limiter.check("a").retry_after
  end
end
