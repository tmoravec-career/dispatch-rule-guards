# One dispatch of a claim: the result at that moment, and the webhook event that
# announced it. sequence is per claim from 1 (Q47); event_id is fixed at creation (Q46).
class DispatchEvent < ApplicationRecord
  WEBHOOK_STATUSES = %w[pending delivered failed not_configured].freeze

  belongs_to :claim, inverse_of: :dispatch_events
end
