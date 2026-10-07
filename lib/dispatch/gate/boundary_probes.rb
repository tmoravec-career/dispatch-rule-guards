module Dispatch
  module Gate
    # Boundary probes generated from the configs themselves (Q29): every numeric
    # threshold (gt/gte/lt/lte) in either rule set is probed at value-1, value and value+1.
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

      # Sorted by field then value, one probe per (field, value). When thresholds next to
      # each other produce the same probe value, the lower threshold's probe is kept.
      def probes
        seen = {}
        thresholds.sort_by { |(field, value), _| [field, value] }.each do |(field, value), (rule, source)|
          [value - 1, value, value + 1].each do |point|
            key = [field, point.to_r]
            seen[key] ||= Probe.new(field, point, value, rule.id, source, probe_claim(rule, field, point))
          end
        end
        seen.values.sort_by { |p| [p.field, p.value] }
      end

      private

      # {[field, value] => [owning rule, :proposed | :base]}. Deduplicated by field and
      # value; a threshold present in both sets is built from the proposed rule, since
      # that is what will ship (Q29 follow-up). Within one set, the rule evaluated first owns it.
      def thresholds
        found = {}
        [[:proposed, @proposed], [:base, @base]].each do |source, config|
          config.rules.each do |rule|
            rule.conditions.select(&:numeric_threshold?).each do |condition|
              found[[condition.field, condition.value]] = [rule, source] unless known?(found, condition)
            end
          end
        end
        found
      end

      # 50000 and 50000.0 are the same threshold.
      def known?(found, condition)
        found.keys.any? { |field, value| field == condition.field && value.to_r == condition.value.to_r }
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

      def satisfying_value(condition)
        case condition.op
        when "eq", "gte", "lte" then condition.value
        when "in" then condition.value.first
        when "gt" then condition.value + 1
        when "lt" then condition.value - 1
        end
      end
    end
  end
end
