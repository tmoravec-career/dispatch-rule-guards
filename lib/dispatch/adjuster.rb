module Dispatch
  # An adjuster and their workload. Mutable only through Roster.
  class Adjuster
    KEYS = %w[id name active licensed_states skills capacity open_claims].freeze

    attr_reader :id, :name, :active, :licensed_states, :skills, :capacity, :open_claims

    def initialize(id:, name:, active:, licensed_states:, skills:, capacity:, open_claims:)
      @id = id
      @name = name
      @active = active
      @licensed_states = licensed_states.dup.freeze
      @skills = skills.dup.freeze
      @capacity = capacity
      @open_claims = open_claims
    end

    def self.from_h(hash)
      new(**hash.transform_keys(&:to_s).slice(*KEYS).transform_keys(&:to_sym))
    end

    def self.validate(item, path, collector)
      unless item.is_a?(Hash)
        collector.add("invalid_value", path, "an adjuster must be a JSON object")
        return
      end
      collector.check_keys(item, path, allowed: KEYS, required: KEYS)
      bad = ->(key, message) { collector.add("invalid_value", "#{path}.#{key}", message) }
      bad.call("id", "must be a non-empty string") if item.key?("id") && !Dispatch.non_empty_string?(item["id"])
      bad.call("name", "must be a string") if item.key?("name") && !item["name"].is_a?(String)
      bad.call("active", "must be true or false") if item.key?("active") && ![true, false].include?(item["active"])
      %w[licensed_states skills].each do |key|
        next unless item.key?(key)

        list = item[key]
        bad.call(key, "must be an array of strings") unless list.is_a?(Array) && list.all? { |v| Dispatch.non_empty_string?(v) }
      end
      if item.key?("licensed_states") && item["licensed_states"].is_a?(Array) &&
         !(item["licensed_states"] - US_STATES).empty?
        bad.call("licensed_states", "must contain uppercase USPS state codes")
      end
      capacity_ok = Dispatch.non_negative_integer?(item["capacity"])
      bad.call("capacity", "must be an integer >= 0") if item.key?("capacity") && !capacity_ok
      return unless item.key?("open_claims")

      if !Dispatch.non_negative_integer?(item["open_claims"])
        bad.call("open_claims", "must be an integer >= 0")
      elsif capacity_ok && item["open_claims"] > item["capacity"]
        bad.call("open_claims", "#{item['open_claims']} open claims exceeds capacity #{item['capacity']}")
      end
    end

    # Exact rational, so 1/3 ties with 2/6 (Q16). Only meaningful when capacity > 0.
    def utilization
      Rational(open_claims, capacity)
    end

    # Capacity 0 is permanently full (Q17).
    def full?
      open_claims >= capacity
    end

    def licensed_in?(state)
      licensed_states.include?(state)
    end

    def skilled_for?(required_skills)
      (required_skills - skills).empty?
    end

    def to_h
      { "id" => id, "name" => name, "active" => active, "licensed_states" => licensed_states.dup,
        "skills" => skills.dup, "capacity" => capacity, "open_claims" => open_claims }
    end

    # Roster needs to bump the counter; nothing else should.
    def increment_open_claims!
      @open_claims += 1
    end
  end
end
