# A claim and its latest dispatch result. The history lives in dispatch_events (Q19).
class Claim < ApplicationRecord
  STATUSES = %w[assigned unassigned].freeze

  belongs_to :adjuster, optional: true
  has_many :dispatch_events, -> { order(:sequence) }, dependent: :destroy, inverse_of: :claim

  # Most recently created first; claims created in the same instant keep reverse creation order (Q35).
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.result_columns(result)
    { status: result.status, queue: result.queue, matched_rule: result.matched_rule, adjuster_id: result.adjuster_id,
      reason_code: result.reason_code, reason: result.reason }
  end

  # The queues a filter may name: every configured queue, general_intake, and any queue
  # that still holds claims, e.g. one removed from the rules (Q35, Q38, Q43).
  def self.known_queue?(queue, rules)
    queue_offered?(queue, rules) || where(queue: queue).exists?
  end

  def self.queue_offered?(queue, rules)
    queue == Dispatch::GENERAL_INTAKE || rules.queues.include?(queue)
  end

  # The same set as a sorted list: the work queue's "Queue" filter options (Q35).
  def self.known_queues(rules)
    (rules.queues + [Dispatch::GENERAL_INTAKE] + distinct.pluck(:queue)).uniq.sort
  end

  def to_engine
    Dispatch::Claim.new(claim_number: claim_number, line_of_business: line_of_business, estimated_loss: estimated_loss,
                        vehicle_value: vehicle_value, cat_event: cat_event, loss_state: loss_state)
  end

  def result
    Dispatch::Result.new(claim_number: claim_number, queue: queue, matched_rule: matched_rule, adjuster_id: adjuster_id,
                         reason_code: reason_code, reason: reason)
  end

  # {claim, dispatch}: contracts/claim_resource.schema.json, shared with the webhook's $defs (Q38).
  def as_resource
    { "claim" => to_engine.to_h, "dispatch" => result.to_h.except("claim_number") }
  end
end
