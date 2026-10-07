require "json_schemer"
require "pathname"

# JSON Schema contracts (STEP_GLOSSARY.md section 7). Schemas are loaded by Pathname, so
# claim_resource.schema.json's $ref into claim_dispatched.schema.json resolves against the
# file's own location, never over the network. Format assertion is on, so
# "format": "date-time" on occurred_at is enforced.
module Contracts
  ROOT = File.expand_path("../..", __dir__)

  def contract_schema(path)
    @contract_schemas ||= {}
    @contract_schemas[path] ||= JSONSchemer.schema(Pathname.new(File.join(ROOT, path)), format: true)
  end

  def contract_errors(document, path)
    contract_schema(path).validate(document).map { |e| e.fetch("error") }
  end

  def assert_conforms(document, path)
    errors = contract_errors(document, path)
    assert_empty errors, "does not conform to #{path}:\n#{errors.join("\n")}\n#{JSON.pretty_generate(document)}"
  end

  # Dotted path with [n]; creates missing object keys on the way.
  def set_at_path(document, path, value)
    *parents, last = path_tokens(path)
    target = parents.reduce(document) { |node, token| token.is_a?(Integer) ? node.fetch(token) : (node[token] ||= {}) }
    target[last] = value
  end

  def remove_at_path(document, path)
    *parents, last = path_tokens(path)
    target = parents.reduce(document) { |node, token| node.fetch(token) }
    return target.delete_at(last) if target.is_a?(Array)

    assert target.key?(last), "no #{path} to remove"
    target.delete(last)
  end

  def path_tokens(path)
    path.scan(/[^.\[\]]+|\[\d+\]/).map { |t| t.start_with?("[") ? Integer(t[1..-2], 10) : t }
  end

  # Canonical samples, built with the engine's own payload builder (Q23).
  def sample_webhook_payload(event)
    claim = Dispatch::Claim.new(claim_number: "CLM-9000", line_of_business: "auto", estimated_loss: 12_000,
                                vehicle_value: 120_000, cat_event: false, loss_state: "CA")
    assigned = event == "claim.assigned"
    result = Dispatch::Result.new(claim_number: "CLM-9000", queue: "luxury_auto", matched_rule: "luxury_auto",
                                  adjuster_id: assigned ? "ADJ-004" : nil,
                                  reason_code: assigned ? "assigned" : "qualified_adjusters_at_capacity",
                                  reason: "Sample reason.")
    payload = Dispatch::Webhook.payload(claim, result, event_id: "6f1c1d6e-6a3b-4b8e-9a51-0c2f5d7e9b10",
                                                       occurred_at: Time.utc(2026, 10, 6, 9), sequence: 1)
    assert_equal event, payload["event"], "unknown webhook event #{event.inspect}"
    JSON.parse(JSON.generate(payload))
  end

  def sample_claim_resource
    payload = sample_webhook_payload("claim.assigned")
    { "claim" => payload["claim"], "dispatch" => payload["dispatch"] }
  end
end

World(Contracts)
