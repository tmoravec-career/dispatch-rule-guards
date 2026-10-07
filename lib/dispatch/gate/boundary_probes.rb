module Dispatch
  module Gate
    # Boundary probes generated from the configs themselves (Q29): every numeric
    # threshold (gt/gte/lt/lte) in either rule set is probed at value-1, value and value+1
    # (whole dollars, so fractional thresholds get the dollars either side; Q55).
    class BoundaryProbes
      # The claim every probe starts from before the owning rule's other conditions apply.
      NEUTRAL = { line_of_business: "liability", estimated_loss: 10_000, vehicle_value: nil,
                  cat_event: false, loss_state: "TX" }.freeze

      # `rule_id`/`source` say which rule's conditions built the claim.
      Probe = Struct.new(:field, :value, :threshold, :rule_id, :source, :claim)

      def initialize(base, proposed)
        @base = base
        @proposed = proposed
      end

      # Sorted by field, value and owning rule. Probes are deduplicated per (rule, field,
      # value), never per value alone (Q55): when two rules' thresholds produce the same
      # probe value, each keeps its own probe built from its own rule's conditions.
      def probes
        seen = {}
        thresholds.each do |rule, condition, source|
          whole_dollar_points(condition.value).each do |point|
            key = [rule.id, condition.field, point]
            seen[key] ||= Probe.new(condition.field, point, condition.value, rule.id, source,
                                    probe_claim(rule, condition.field, point))
          end
        end
        seen.values.sort_by { |p| [p.field, p.value, p.rule_id] }
      end

      private

      # [[rule, condition, :proposed | :base]]. Every numeric threshold in the proposed rules,
      # plus base thresholds whose (field, value) the proposed rules no longer have: a
      # threshold present in both is built from the proposed rule, since that is what will
      # ship (Q29 follow-up); one that exists only in base still uses the base rule.
      def thresholds
        proposed = numeric_conditions(@proposed).map { |rule, c| [rule, c, :proposed] }
        shipped = proposed.map { |_, c, _| [c.field, c.value.to_r] }
        base = numeric_conditions(@base).reject { |_, c| shipped.include?([c.field, c.value.to_r]) }
        proposed + base.map { |rule, c| [rule, c, :base] }
      end

      def numeric_conditions(config)
        config.rules.flat_map { |rule| rule.conditions.select(&:numeric_threshold?).map { |c| [rule, c] } }
      end

      # Claims are whole dollars (Q1), so probes are too (Q55 G1): floor(t)-1, floor(t),
      # ceil(t), ceil(t)+1. For a whole-dollar t that is t-1, t, t+1.
      def whole_dollar_points(threshold)
        low = threshold.floor
        high = threshold.ceil
        [low - 1, low, high, high + 1].uniq
      end

      def probe_claim(rule, field, point)
        attrs = NEUTRAL.dup
        rule.conditions.each do |condition|
          next if condition.field == field

          attrs[condition.field.to_sym] = satisfying_value(condition)
        end
        attrs[field.to_sym] = point
        Claim.new(claim_number: "PROBE-#{field}-#{point}", **attrs)
      end

      # A whole-dollar value that satisfies the condition (eq/in values are used as given).
      def satisfying_value(condition)
        value = condition.value
        case condition.op
        when "eq" then value
        when "in" then value.first
        when "gte" then value.ceil
        when "lte" then value.floor
        when "gt" then value.floor + 1
        when "lt" then value.ceil - 1
        end
      end
    end
  end
end
