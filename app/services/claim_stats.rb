# GET /api/claims/stats (Q43): count and total estimated_loss per queue, per status and
# overall, from a single GROUP BY query over claims. by_queue always lists every configured
# queue plus general_intake (zeros when empty) and any other queue that still holds claims.
class ClaimStats
  def initialize(rules: DispatchSettings.rules)
    @rules = rules
  end

  def to_h
    rows = Claim.group(:queue, :status)
                .pluck(:queue, :status, Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(estimated_loss), 0)"))
    by_queue = Hash.new { |h, k| h[k] = zero }
    (@rules.queues + [Dispatch::GENERAL_INTAKE]).each { |queue| by_queue[queue] }
    by_status = Claim::STATUSES.index_with { zero }
    total = zero
    rows.each do |queue, status, count, loss|
      [by_queue[queue], by_status.fetch(status), total].each do |bucket|
        bucket["count"] += count.to_i
        bucket["total_estimated_loss"] += loss.to_i
      end
    end
    {
      "by_queue" => by_queue.sort.map { |queue, sums| { "queue" => queue }.merge(sums) },
      "by_status" => by_status.map { |status, sums| { "status" => status }.merge(sums) },
      "total" => total
    }
  end

  private

  def zero
    { "count" => 0, "total_estimated_loss" => 0 }
  end
end
