require "json"

module Dispatch
  module Gate
    # Replays the same claims, in the same order, through the base and proposed rules,
    # each from a fresh copy of the same starting roster (Q31), then diffs the outcomes
    # and evaluates the policy (Q25-Q33). The report has no timestamps or paths, so
    # identical inputs give byte-identical output.
    class Impact
      def initialize(base:, proposed:, claims:, roster:, policy: Policy.new, seed: nil)
        @base = base
        @proposed = proposed
        @claims = claims
        @roster = roster
        @policy = policy
        @seed = seed
      end

      def self.breached?(report)
        !report["policy_breaches"].empty?
      end

      def self.to_json(report)
        "#{JSON.pretty_generate(report)}\n"
      end

      def report
        base_results = replay(@base)
        proposed_results = replay(@proposed)
        pairs = @claims.each_index.map { |i| [base_results[i], proposed_results[i]] }

        rerouted = rerouted(pairs)
        newly_unassigned = newly_unassigned(pairs)
        probe_results = probes
        probe_changes = probe_results.select { |p| p["changed"] }
        reroute_pct = @claims.empty? ? Rational(0) : Rational(rerouted.size * 100, @claims.size)

        {
          "summary" => {
            "replayed_claims" => @claims.size,
            "seed" => @seed,
            "reroute_pct" => Policy.display_pct(reroute_pct),
            "unassigned_base" => base_results.count { |r| !r.assigned? },
            "unassigned_proposed" => proposed_results.count { |r| !r.assigned? }
          },
          "policy_breaches" => @policy.breaches(new_unassigned: newly_unassigned.size, reroute_pct: reroute_pct,
                                                probe_changes: probe_changes.size),
          "newly_unassigned" => newly_unassigned,
          "newly_assigned" => newly_assigned(pairs),
          "queue_changes" => queue_changes(base_results, proposed_results),
          "rerouted" => rerouted,
          "boundary_probes" => probe_results,
          "boundary_probe_changes" => probe_changes
        }
      end

      private

      def replay(config)
        engine = Engine.new(config)
        roster = @roster.copy
        @claims.map { |claim| engine.dispatch(claim, roster) }
      end

      # Assigned under base, unassigned under proposed (Q27).
      def newly_unassigned(pairs)
        pairs.select { |b, p| b.assigned? && !p.assigned? }.map do |b, p|
          { "claim_number" => p.claim_number, "queue" => p.queue, "reason_code" => p.reason_code,
            "base_queue" => b.queue, "base_adjuster" => b.adjuster_id }
        end
      end

      # Unassigned under base, assigned under proposed; informational only (Q27).
      def newly_assigned(pairs)
        pairs.select { |b, p| !b.assigned? && p.assigned? }.map do |b, p|
          { "claim_number" => p.claim_number, "queue" => p.queue, "adjuster" => p.adjuster_id,
            "base_queue" => b.queue, "base_reason_code" => b.reason_code }
        end
      end

      # A reroute is a different queue; a different adjuster in the same queue is not (Q25).
      def rerouted(pairs)
        pairs.reject { |b, p| b.queue == p.queue }.map do |b, p|
          { "claim_number" => b.claim_number, "base_queue" => b.queue, "proposed_queue" => p.queue,
            "base_matched_rule" => b.matched_rule, "proposed_matched_rule" => p.matched_rule }
        end
      end

      # Claims routed to each queue, assigned or not (Q33). Changed queues only, by name.
      def queue_changes(base_results, proposed_results)
        base_counts = base_results.map(&:queue).tally
        proposed_counts = proposed_results.map(&:queue).tally
        (base_counts.keys | proposed_counts.keys).sort.filter_map do |queue|
          before = base_counts.fetch(queue, 0)
          after = proposed_counts.fetch(queue, 0)
          next if before == after

          { "queue" => queue, "base" => before, "proposed" => after, "delta" => after - before }
        end
      end

      # Probes compare routing only (queue and matched rule), not assignment (Q29).
      def probes
        base_engine = Engine.new(@base)
        proposed_engine = Engine.new(@proposed)
        BoundaryProbes.new(@base, @proposed).probes.map do |probe|
          before = base_engine.route(probe.claim)
          after = proposed_engine.route(probe.claim)
          { "field" => probe.field, "value" => probe.value, "threshold" => probe.threshold,
            "threshold_rule" => probe.rule_id, "threshold_source" => probe.source.to_s,
            "base_queue" => before.queue, "base_matched_rule" => before.rule_id,
            "proposed_queue" => after.queue, "proposed_matched_rule" => after.rule_id,
            "changed" => before.queue != after.queue || before.rule_id != after.rule_id }
        end
      end
    end
  end
end
