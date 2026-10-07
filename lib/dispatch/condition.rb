module Dispatch
  # One "<field> <op> <value>" clause of a rule (Q8). There is no neq/not_in in v1.
  class Condition
    NUMERIC_OPERATORS = %w[gt gte lt lte].freeze
    OPERATORS = (%w[eq in] + NUMERIC_OPERATORS).freeze
    KEYS = %w[field op value].freeze

    attr_reader :field, :op, :value

    def initialize(field:, op:, value:)
      @field = field
      @op = op
      @value = value.is_a?(Array) ? value.dup.freeze : value
      freeze
    end

    # Validates a parsed condition object, adding errors under `path`.
    def self.validate(hash, path, collector)
      unless hash.is_a?(Hash)
        collector.add("invalid_value", path, "a condition must be a JSON object")
        return
      end
      collector.check_keys(hash, path, allowed: KEYS, required: KEYS)
      if hash.key?("field") && !ROUTING_FIELDS.include?(hash["field"])
        collector.add("unknown_field", "#{path}.field",
                      "#{hash['field'].inspect} is not a routing field (#{ROUTING_FIELDS.join(', ')})")
      end
      if hash.key?("op") && !OPERATORS.include?(hash["op"])
        collector.add("unknown_operator", "#{path}.op", "#{hash['op'].inspect} is not an operator (#{OPERATORS.join(', ')})")
      end
      validate_value(hash, path, collector) if hash.key?("value")
    end

    # The JSON type each routing field holds (Q1). Operators and values must agree with it (Q55 G3).
    FIELD_TYPES = { "line_of_business" => :string, "loss_state" => :string, "cat_event" => :boolean,
                    "estimated_loss" => :number, "vehicle_value" => :number }.freeze

    # Enum fields: eq/in values must be allowed members, the same sets claims are checked
    # against (Q1), so a typo like "TXX" or "Auto" can't silently disable a rule (Q55 G6).
    FIELD_ENUMS = { "line_of_business" => LINES_OF_BUSINESS, "loss_state" => US_STATES }.freeze

    def self.validate_value(hash, path, collector)
      value = hash["value"]
      field_type = FIELD_TYPES[hash["field"]]
      case hash["op"]
      when *NUMERIC_OPERATORS
        # A numeric-looking string is still a string: "100000" must not silently compare as text.
        # 1e400 parses to Infinity, which is not a usable threshold either (Q55).
        unless Dispatch.finite_number?(value)
          collector.add("non_numeric_threshold", "#{path}.value", "#{hash['op']} needs a finite JSON number, got #{value.inspect}")
        end
        if field_type && field_type != :number
          collector.add("invalid_value", "#{path}.op", "#{hash['op']} only applies to numeric fields, not #{hash['field']}")
        end
      when "in"
        if value.is_a?(Array) && !value.empty? && value.all? { |v| scalar?(v) }
          validate_scalars(value, field_type, hash, path, collector)
        else
          collector.add("invalid_value", "#{path}.value", "in needs a non-empty array of scalars, got #{value.inspect}")
        end
      when "eq"
        if scalar?(value)
          validate_scalars([value], field_type, hash, path, collector)
        else
          collector.add("invalid_value", "#{path}.value", "eq needs a scalar, got #{value.inspect}")
        end
      end
    end

    # Non-finite numbers are non_numeric_threshold; a value of the wrong type for the field is invalid_value.
    def self.validate_scalars(values, field_type, hash, path, collector)
      if values.any? { |v| v.is_a?(Float) && !v.finite? }
        collector.add("non_numeric_threshold", "#{path}.value", "#{hash['op']} value must be a finite number")
      elsif field_type && !values.all? { |v| type_of(v) == field_type }
        collector.add("invalid_value", "#{path}.value", "#{hash['field']} holds #{field_type} values, got #{hash['value'].inspect}")
      elsif (allowed = FIELD_ENUMS[hash["field"]]) && !(values - allowed).empty?
        collector.add("invalid_value", "#{path}.value",
                      "#{(values - allowed).map(&:inspect).join(', ')} is not a valid #{hash['field']}")
      end
    end

    def self.type_of(value)
      case value
      when String then :string
      when true, false then :boolean
      when Numeric then :number
      end
    end

    def self.scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    def self.from_h(hash)
      new(field: hash["field"], op: hash["op"], value: hash["value"])
    end

    def numeric_threshold?
      NUMERIC_OPERATORS.include?(op)
    end

    # False whenever the claim lacks the field (Q3) or the types don't compare.
    def matches?(claim)
      actual = claim[field]
      return false if actual.nil?

      case op
      when "eq" then actual == value && boolean?(actual) == boolean?(value)
      when "in" then value.any? { |v| v == actual && boolean?(v) == boolean?(actual) }
      when "gt" then numeric?(actual) && actual > value
      when "gte" then numeric?(actual) && actual >= value
      when "lt" then numeric?(actual) && actual < value
      when "lte" then numeric?(actual) && actual <= value
      else false
      end
    end

    def to_h
      { "field" => field, "op" => op, "value" => value }
    end

    # Same clause syntax as the feature files' rules tables, e.g. "loss_state in TX,FL,LA".
    def to_s
      shown = value.is_a?(Array) ? value.join(",") : value.to_s
      "#{field} #{op} #{shown}"
    end

    private

    def numeric?(v)
      v.is_a?(Numeric)
    end

    def boolean?(v)
      v == true || v == false
    end
  end
end
