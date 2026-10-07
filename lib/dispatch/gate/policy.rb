module Dispatch
  module Gate
    # The gate's policy thresholds (Q26, Q28, Q30). Each one fails only when the actual
    # value is strictly greater. They are flags because the team owns them.
    class Policy
      COUNT = /\A\d+\z/
      PERCENT = /\A\d+(\.\d+)?\z/

      attr_reader :max_new_unassigned, :max_reroute_pct, :max_probe_changes

      def initialize(max_new_unassigned: 0, max_reroute_pct: 10, max_probe_changes: 0)
        @max_new_unassigned = count(max_new_unassigned, "max-new-unassigned")
        @max_reroute_pct = percent(max_reroute_pct, "max-reroute-pct")
        @max_probe_changes = count(max_probe_changes, "max-probe-changes")
        freeze
      end

      # `reroute_pct` is the exact (unrounded) Rational; only the display is rounded (Q32 follow-up).
      def breaches(new_unassigned:, reroute_pct:, probe_changes:)
        list = []
        if new_unassigned > max_new_unassigned
          list << breach("max_new_unassigned", max_new_unassigned, new_unassigned)
        end
        if reroute_pct > max_reroute_pct
          list << breach("max_reroute_pct", self.class.number(max_reroute_pct), self.class.display_pct(reroute_pct))
        end
        if probe_changes > max_probe_changes
          list << breach("max_probe_changes", max_probe_changes, probe_changes)
        end
        list
      end

      # Rounded to 1 decimal for display, e.g. 1 of 3 -> 33.3.
      def self.display_pct(rational)
        rational.round(1).to_f
      end

      # Integer when whole, Float otherwise, so JSON shows 10 rather than 10.0 or "10/1".
      def self.number(rational)
        rational.denominator == 1 ? rational.to_i : rational.to_f
      end

      private

      def breach(policy, threshold, actual)
        { "policy" => policy, "threshold" => threshold, "actual" => actual }
      end

      def count(value, name)
        return value if value.is_a?(Integer) && value >= 0
        return Integer(value, 10) if value.is_a?(String) && value.match?(COUNT)

        raise ArgumentError, "--#{name} must be a whole number >= 0, got #{value.inspect}"
      end

      def percent(value, name)
        text = value.is_a?(Numeric) ? value.to_s : value
        return Rational(text) if text.is_a?(String) && text.match?(PERCENT)

        raise ArgumentError, "--#{name} must be a number >= 0, got #{value.inspect}"
      end
    end
  end
end
