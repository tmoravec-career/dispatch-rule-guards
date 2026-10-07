# STEP_GLOSSARY.md section 7: the webhook, its contract and its integrity (Q23, Q24, Q45-Q47),
# plus the claim resource contract (Q38).

# --- the endpoint ----------------------------------------------------------------

Given("the webhook endpoint responds with status {int}") do |status|
  webhook_endpoint(status)
end

Given("the webhook endpoint times out") do
  webhook_endpoint(:timeout)
end

Given("the webhook endpoint refuses connections") do
  webhook_endpoint(:refused)
end

Given("no webhook endpoint is configured") do
  DispatchSettings.webhook_url = nil
  @forbid_outbound_http = true
end

Given("the webhook signing secret is {string}") do |secret|
  DispatchSettings.webhook_secret = secret
end

# --- what was sent -------------------------------------------------------------------

Then("{int} webhook(s) has/have been sent") do |count|
  assert_equal count, webhook_deliveries.size
end

Then("no webhook is sent") do
  assert_empty webhook_deliveries
  assert_equal 0, outbound_request_count, "outbound HTTP requests were made"
end

Then("the last webhook payload conforms to {string}") do |schema|
  assert_conforms(last_webhook.payload, schema)
end

Then("every webhook payload conforms to {string}") do |schema|
  refute_empty webhook_deliveries, "no webhook has been sent"
  webhook_deliveries.each { |delivery| assert_conforms(delivery.payload, schema) }
end

Then("the last webhook payload at {string} is {json}") do |path, expected|
  actual = json_at(last_webhook.payload, path)
  assert json_typed_equal?(actual, expected), "#{path}: expected #{expected.inspect}, got #{actual.inspect}"
end

Then("the webhook event IDs are all different") do
  ids = webhook_deliveries.map { |d| d.payload["event_id"] }
  assert_equal ids.uniq, ids
end

Then("the webhook delivery for claim {string} is recorded as {string}") do |claim_number, status|
  claim = Claim.find_by(claim_number: claim_number) or flunk("no claim #{claim_number}")
  assert_equal status, claim.dispatch_events.last.webhook_status
end

Then("the webhooks for claim {string} have strictly increasing {string}") do |claim_number, field|
  values = webhooks_for_claim(claim_number).map do |delivery|
    value = delivery.payload.fetch(field)
    field == "occurred_at" ? Time.iso8601(value) : Integer(value)
  end
  assert_operator values.size, :>=, 2, "fewer than two webhooks for #{claim_number}"
  values.each_cons(2) { |a, b| assert_operator a, :<, b, "#{field} is not strictly increasing: #{values.inspect}" }
end

# --- signature (Q45) --------------------------------------------------------------------

Then("the last webhook has header {string} starting with {string}") do |name, prefix|
  value = last_webhook.header(name)
  refute_nil value, "no #{name} header"
  assert value.start_with?(prefix), "#{name}: #{value.inspect}"
end

Then("the last webhook signature verifies with secret {string}") do |secret|
  delivery = last_webhook
  assert Dispatch::Webhook.verify_signature(delivery.body, delivery.header(Dispatch::Webhook::SIGNATURE_HEADER), secret)
end

Then("the last webhook signature does not verify with secret {string}") do |secret|
  delivery = last_webhook
  refute Dispatch::Webhook.verify_signature(delivery.body, delivery.header(Dispatch::Webhook::SIGNATURE_HEADER), secret)
end

# Byte-level: the only difference is the substituted bytes; the original header is kept.
When("the last webhook body is tampered with by replacing {string} with {string}") do |search, replacement|
  delivery = last_webhook
  bytes = delivery.body.b
  assert bytes.include?(search.b), "#{search.inspect} is not in the webhook body"
  delivery.body = bytes.sub(search.b, replacement.b)
end

When("the last webhook body is re-serialised with different whitespace") do
  delivery = last_webhook
  reserialised = JSON.pretty_generate(JSON.parse(delivery.body))
  refute_equal delivery.body, reserialised
  delivery.body = reserialised
end

# --- de-duplication (Q46) -------------------------------------------------------------

Given("a de-duplicating test consumer") do
  @consumer = DeduplicatingConsumer.new
end

When("the last webhook is delivered to the test consumer {int} times") do |times|
  body = last_webhook.body
  times.times { @consumer.receive(body) }
end

When("every webhook is delivered to the test consumer") do
  webhook_deliveries.each { |delivery| @consumer.receive(delivery.body) }
end

Then("the test consumer has processed {int} event(s)") do |count|
  assert_equal count, @consumer.processed
end

Then("the test consumer has ignored {int} duplicate(s)") do |count|
  assert_equal count, @consumer.duplicates
end

# --- contracts --------------------------------------------------------------------------

Given("a valid {string} webhook payload") do |event|
  @payload = sample_webhook_payload(event)
  assert_conforms(@payload, "contracts/claim_dispatched.schema.json")
end

Given("a valid claim resource payload") do
  @payload = sample_claim_resource
  assert_conforms(@payload, "contracts/claim_resource.schema.json")
end

When("I set {string} in the payload to {json}") do |path, value|
  set_at_path(@payload, path, value)
end

When("I remove {string} from the payload") do |path|
  remove_at_path(@payload, path)
end

Then("the payload does not conform to {string}") do |schema|
  refute_empty contract_errors(@payload, schema), "the edited payload still conforms to #{schema}: #{@payload.inspect}"
end
