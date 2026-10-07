require_relative "../app_helper"
require "socket"

# The webhook's 2 s is one wall-clock deadline per attempt (Q57), checked against real
# local TCP endpoints: WebMock replaces Net::HTTP's socket, so it can't show a slow one.
# Also: delivery runs off the request thread outside test.
class WebhookDeadlineTest < ActiveSupport::TestCase
  include AppTestHelpers

  # The 2 s deadline plus generous slack for a busy CI runner (BUG-025). The regression
  # this guards against (BUG-011) blocked for 21-59 s, so 4 s still catches it easily.
  MAX_SECONDS = 4.0

  def setup
    super
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def teardown
    WebMock.disable_net_connect!
    super
  end

  # A server on a free local port that accepts one connection, reads the request and then
  # behaves as `mode` says. Runs until the test ends.
  def with_endpoint(mode)
    server = TCPServer.new("127.0.0.1", 0)
    done = Queue.new
    thread = Thread.new do
      client = server.accept
      client.readpartial(64 * 1024)
      if mode == :trickle
        # Headers promise 1000 bytes, then one byte every 0.2 s: each read succeeds, so
        # a per-read timeout never fires.
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 1000\r\n\r\n")
        50.times do
          break unless done.empty?

          client.write("x")
          done.pop(timeout: 0.2)
        end
      else
        done.pop(timeout: 10) # never answers
      end
    rescue IOError, SystemCallError
      nil # the notifier hung up, as it should
    ensure
      client&.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}/hook"
  ensure
    done << :stop
    thread&.join(5)
    server&.close
  end

  def stored_event
    ClaimDispatcher.new(notifier: WebhookNotifier.new(url: nil)).create(claim_attrs("C-1")).dispatch_events.sole
  end

  def timed_delivery(url)
    event = stored_event
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    WebhookNotifier.new(url: url, secret: "s3cret").deliver(event)
    [event.reload, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  test "a trickling endpoint is cut off at the deadline and recorded as failed" do
    with_endpoint(:trickle) do |url|
      event, elapsed = timed_delivery(url)
      assert_operator elapsed, :<=, MAX_SECONDS
      assert_operator elapsed, :>=, 1.9, "gave up before the deadline"
      assert_equal "failed", event.webhook_status
      assert_includes event.webhook_error, "DeadlineExceeded"
    end
  end

  test "an endpoint that never answers is cut off at the deadline and recorded as failed" do
    with_endpoint(:silent) do |url|
      event, elapsed = timed_delivery(url)
      assert_operator elapsed, :<=, MAX_SECONDS
      assert_equal "failed", event.webhook_status
    end
  end

  test "outside test, dispatch queues the delivery and returns with the event pending" do
    DispatchSettings.webhook_url = "http://hooks.test/in"
    DispatchSettings.webhook_secret = "s3cret"
    queued = []
    queue = Object.new
    queue.define_singleton_method(:enqueue) { |job| queued << job }
    DispatchSettings.stub(:webhook_delivery, :async) do
      DispatchSettings.stub(:webhook_queue, queue) do
        claim = ClaimDispatcher.new.create(claim_attrs("C-1"))
        event = claim.dispatch_events.sole
        assert_equal "pending", event.webhook_status
        assert_equal [{ event_id: event.id, url: "http://hooks.test/in", secret: "s3cret" }], queued
      end
    end
    assert_not_requested(:post, "http://hooks.test/in")
  end

  test "the queue runs jobs on its own thread, in order, and survives a failing job" do
    seen = Queue.new
    queue = WebhookQueue.new do |job|
      raise "boom" if job == :bad

      seen << [job, Thread.current]
    end
    [1, :bad, 2].each { |job| queue.enqueue(job) }
    assert queue.shutdown(timeout: 5), "the worker did not finish"
    results = Array.new(seen.size) { seen.pop }
    assert_equal [1, 2], results.map(&:first)
    results.each { |_, thread| refute_same Thread.current, thread }
  end
end
