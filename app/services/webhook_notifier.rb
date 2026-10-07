require "net/http"

# Delivers a dispatch event's webhook (Q24): one attempt, made after the dispatch has
# committed. The body is the event's stored bytes and is signed with X-Dispatch-Signature
# (Q45). Every outcome is recorded on the event; failures are logged and never raised, so
# a webhook outage can't block or undo routing.
#
# The attempt has one overall wall-clock deadline of 2 s covering connect, write and read
# together (Q57). Net::HTTP's timeouts are per operation (an endpoint trickling a byte at
# a time never trips read_timeout) and a blocking connect isn't reliably interruptible on
# Windows, so the request runs on its own thread and the caller waits at most the
# deadline. A request still running then is abandoned and its outcome discarded.
class WebhookNotifier
  DEADLINE_SECONDS = 2

  class DeadlineExceeded < StandardError; end

  def initialize(url: DispatchSettings.webhook_url, secret: DispatchSettings.webhook_secret, logger: Rails.logger,
                 deadline: DEADLINE_SECONDS)
    @url = url
    @secret = secret
    @logger = logger
    @deadline = deadline
  end

  def deliver(event)
    # No URL configured: nothing is sent and nothing fails.
    return record(event, "not_configured") if @url.blank?
    raise "no webhook signing secret is configured" if @secret.blank?

    response = post_within_deadline(event.payload)
    if response.is_a?(Net::HTTPSuccess)
      record(event, "delivered", code: response.code.to_i)
    else
      failed(event, "HTTP #{response.code}", code: response.code.to_i)
    end
  rescue StandardError => e
    failed(event, "#{e.class}: #{e.message}")
  end

  private

  # Thread#join returns nil at the deadline and re-raises the request's own error.
  def post_within_deadline(body)
    request = Thread.new do
      Thread.current.report_on_exception = false
      post(body)
    end
    return request.value if request.join(@deadline)

    request.kill
    raise DeadlineExceeded, "no complete response within #{@deadline} s"
  end

  def post(body)
    uri = URI(@url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    # Per-operation limits too, so an abandoned request thread ends soon after the deadline.
    http.open_timeout = http.read_timeout = http.write_timeout = http.ssl_timeout = @deadline
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request[Dispatch::Webhook::SIGNATURE_HEADER] = Dispatch::Webhook.signature(body, @secret)
    request.body = body
    http.request(request)
  end

  def failed(event, error, code: nil)
    @logger.warn("webhook #{event.event_id} for claim #{event.claim_id} failed: #{error}")
    record(event, "failed", code: code, error: error)
  end

  # Recording must not raise either: the dispatch it describes has already committed.
  def record(event, status, code: nil, error: nil)
    event.update_columns(webhook_status: status, webhook_response_code: code, webhook_error: error&.truncate(255),
                         webhook_attempted_at: status == "not_configured" ? nil : Clock.now)
    event
  rescue StandardError => e
    @logger.error("could not record webhook #{status} for event #{event.event_id}: #{e.class}: #{e.message}")
    event
  end
end
