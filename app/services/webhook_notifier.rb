require "net/http"

# Delivers a dispatch event's webhook (Q24): one attempt, made after the dispatch has
# committed, with a 2 s timeout. The body is the event's stored bytes and is signed with
# X-Dispatch-Signature (Q45). Every outcome is recorded on the event; failures are
# logged and never raised, so a webhook outage can't block or undo routing.
class WebhookNotifier
  TIMEOUT_SECONDS = 2

  def initialize(url: DispatchSettings.webhook_url, secret: DispatchSettings.webhook_secret, logger: Rails.logger)
    @url = url
    @secret = secret
    @logger = logger
  end

  def deliver(event)
    # No URL configured: nothing is sent and nothing fails.
    return record(event, "not_configured") if @url.blank?
    raise "no webhook signing secret is configured" if @secret.blank?

    response = post(event.payload)
    if response.is_a?(Net::HTTPSuccess)
      record(event, "delivered", code: response.code.to_i)
    else
      failed(event, "HTTP #{response.code}", code: response.code.to_i)
    end
  rescue StandardError => e
    failed(event, "#{e.class}: #{e.message}")
  end

  private

  def post(body)
    uri = URI(@url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = http.read_timeout = http.write_timeout = http.ssl_timeout = TIMEOUT_SECONDS
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
