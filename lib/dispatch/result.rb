module Dispatch
  # The outcome of dispatching one claim. Fall-through is not a reason code: it
  # shows as matched_rule nil with queue general_intake (Q15).
  class Result
    ASSIGNED = "assigned".freeze
    NO_QUALIFIED_ADJUSTER = "no_qualified_adjuster".freeze
    QUALIFIED_ADJUSTERS_AT_CAPACITY = "qualified_adjusters_at_capacity".freeze

    attr_reader :claim_number, :queue, :matched_rule, :adjuster_id, :reason_code, :reason

    def initialize(claim_number:, queue:, matched_rule:, adjuster_id:, reason_code:, reason:)
      @claim_number = claim_number
      @queue = queue
      @matched_rule = matched_rule
      @adjuster_id = adjuster_id
      @reason_code = reason_code
      @reason = reason
      freeze
    end

    def assigned?
      !adjuster_id.nil?
    end

    def status
      assigned? ? "assigned" : "unassigned"
    end

    def to_h
      { "claim_number" => claim_number, "status" => status, "queue" => queue, "matched_rule" => matched_rule,
        "adjuster_id" => adjuster_id, "reason_code" => reason_code, "reason" => reason }
    end

    def ==(other)
      other.is_a?(Result) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
