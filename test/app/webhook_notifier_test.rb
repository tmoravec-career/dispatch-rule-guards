require_relative "../app_helper"

# WebhookNotifier (Q24, Q45): one signed attempt after commit, outcomes recorded, never raises.
class WebhookNotifierTest < ActiveSupport::TestCase
  include AppTestHelpers

  URL = "http://hooks.test/in".freeze

  def setup
    super
    DispatchSettings.webhook_url = URL
    DispatchSettings.webhook_secret = "s3cret"
  end

  test "a delivery carries the stored bytes and their HMAC" do
    stub_request(:post, URL).to_return(status: 204)
    event = ClaimDispatcher.new.create(claim_attrs("C-1")).dispatch_events.sole
    assert_equal ["delivered", 204], [event.webhook_status, event.webhook_response_code]
    assert_requested(:post, URL, body: event.payload,
                                 headers: { "X-Dispatch-Signature" => Dispatch::Webhook.signature(event.payload, "s3cret"),
                                            "Content-Type" => "application/json" })
  end

  test "failures are recorded and the dispatch stands" do
    failures = { "HTTP 500" => ->(s) { s.to_return(status: 500) }, "Net::OpenTimeout" => ->(s) { s.to_timeout },
                 "ECONNREFUSED" => ->(s) { s.to_raise(Errno::ECONNREFUSED) } }
    failures.each_with_index do |(error, stub), i|
      WebMock.reset!
      stub.call(stub_request(:post, URL))
      claim = ClaimDispatcher.new.create(claim_attrs("C-#{i}"))
      event = claim.dispatch_events.sole
      assert_equal ["assigned", "failed"], [claim.status, event.webhook_status]
      assert_includes event.webhook_error, error
    end
  end

  test "a missing secret fails the delivery instead of sending it unsigned" do
    DispatchSettings.webhook_secret = nil
    claim = ClaimDispatcher.new.create(claim_attrs("C-1"))
    assert_equal "failed", claim.dispatch_events.sole.webhook_status
    assert_not_requested(:post, URL)
  end

  test "an error while recording the outcome is logged, not raised" do
    stub_request(:post, URL).to_return(status: 200)
    event = ClaimDispatcher.new(notifier: WebhookNotifier.new(url: nil)).create(claim_attrs("C-1")).dispatch_events.sole
    event.define_singleton_method(:update_columns) { |*| raise ActiveRecord::StatementInvalid, "database is locked" }
    assert_same event, WebhookNotifier.new.deliver(event)
  end
end
