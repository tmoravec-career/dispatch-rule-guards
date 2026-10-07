require "webmock"

# A recording fake webhook receiver (STEP_GLOSSARY.md section 7). WebMock intercepts the
# app's Net::HTTP call; each stub records the raw bytes and headers it received before
# answering, failing, timing out or refusing. Real outbound HTTP is never allowed
# (localhost stays open for a browser-driven app server).
WebMock.enable!
WebMock.disable_net_connect!(allow_localhost: true)

module WebhookSink
  URL = "http://webhooks.test/claims".freeze

  # One received delivery. `body` is the raw bytes and may be tampered with by a step.
  Delivery = Struct.new(:body, :headers) do
    def header(name)
      headers.find { |key, _| key.casecmp?(name) }&.last
    end

    def payload
      JSON.parse(body)
    end
  end

  def webhook_deliveries
    @webhook_deliveries ||= []
  end

  def last_webhook
    webhook_deliveries.last or flunk("no webhook has been sent")
  end

  # Points the app at the fake receiver, which then behaves as `behaviour` says:
  # an Integer status, :timeout or :refused.
  def webhook_endpoint(behaviour)
    DispatchSettings.webhook_url = URL
    deliveries = webhook_deliveries
    WebMock.stub_request(:post, URL).to_return do |request|
      deliveries << Delivery.new(request.body.dup, request.headers.to_h)
      case behaviour
      when :timeout then raise Net::OpenTimeout, "execution expired"
      when :refused then raise Errno::ECONNREFUSED, "Failed to open TCP connection to #{URL}"
      else { status: behaviour, body: "" }
      end
    end
  end

  # Every outbound request WebMock saw, stubbed or not.
  def outbound_request_count
    WebMock::RequestRegistry.instance.requested_signatures.hash.values.sum
  end

  def webhooks_for_claim(claim_number)
    webhook_deliveries.select { |d| d.payload.dig("claim", "claim_number") == claim_number }
  end
end

# A consumer that processes each event_id at most once (Q46).
class DeduplicatingConsumer
  attr_reader :processed, :duplicates

  def initialize
    @seen = Set.new
    @processed = 0
    @duplicates = 0
  end

  def receive(body)
    if @seen.add?(JSON.parse(body).fetch("event_id"))
      @processed += 1
    else
      @duplicates += 1
    end
  end
end

World(WebhookSink)

Before("@api or @ui or @load") do
  WebMock.reset!
end

# "no webhook endpoint is configured": any outbound HTTP at all fails the scenario.
After do |scenario|
  if @forbid_outbound_http && !scenario.failed?
    count = outbound_request_count
    raise "no webhook endpoint was configured, yet #{count} outbound HTTP request(s) were made" if count.positive?
  end
end
