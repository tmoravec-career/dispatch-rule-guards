require "openssl"
require "securerandom"

module Dispatch
  # Pure helpers for the claim.assigned / claim.unassigned webhook. The shape is pinned
  # by contracts/claim_dispatched.schema.json (Q23); delivery lives in the app.
  module Webhook
    SIGNATURE_HEADER = "X-Dispatch-Signature".freeze
    SIGNATURE_PREFIX = "sha256=".freeze

    module_function

    # Builds the payload hash. `sequence` is per claim, starting at 1 (Q47); `occurred_at`
    # is rendered in UTC with millisecond precision.
    def payload(claim, result, event_id:, occurred_at:, sequence:)
      raise ArgumentError, "sequence must be an integer >= 1" unless sequence.is_a?(Integer) && sequence >= 1

      {
        "event" => result.assigned? ? "claim.assigned" : "claim.unassigned",
        "event_id" => event_id,
        "occurred_at" => format_time(occurred_at),
        "sequence" => sequence,
        "claim" => {
          "claim_number" => claim.claim_number,
          "line_of_business" => claim.line_of_business,
          "estimated_loss" => claim.estimated_loss,
          "vehicle_value" => claim.vehicle_value,
          "cat_event" => claim.cat_event,
          "loss_state" => claim.loss_state
        },
        "dispatch" => result.to_h.reject { |key, _| key == "claim_number" }
      }
    end

    def format_time(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # A new event ID. Assigned once when the event is created; redeliveries reuse it (Q46).
    def generate_event_id
      SecureRandom.uuid
    end

    # Header value for X-Dispatch-Signature over the exact bytes sent (Q45).
    def signature(raw_body, secret)
      SIGNATURE_PREFIX + OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
    end

    # Constant-time check of a received header against the raw body.
    def verify_signature(raw_body, header, secret)
      return false unless header.is_a?(String)

      OpenSSL.secure_compare(signature(raw_body, secret), header)
    end
  end
end
