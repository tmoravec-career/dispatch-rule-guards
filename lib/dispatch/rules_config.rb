module Dispatch
  # A validated rules config: {"rules":[{"id","priority","conditions","queue","required_skills"}]}.
  #
  # Validation is strict (Q6-Q12): no keys beyond the schema at any level, so a typo
  # or an attempt to configure licensing (Q11) is rejected as unknown_field. Every
  # error is collected and raised together in a ConfigError; nothing is partially loaded.
  class RulesConfig
    TOP_LEVEL_KEYS = %w[rules].freeze

    attr_reader :rules

    def self.load_file(path)
      from_h(Dispatch.read_json_file(path), source: path)
    end

    def self.parse(json_text, source: nil)
      from_h(Dispatch.parse_json(json_text, source: source), source: source)
    end

    def self.from_h(data, source: nil)
      collector = ErrorCollector.new
      validate(data, collector)
      collector.raise_if_any!(source)
      new(data["rules"].map { |r| Rule.from_h(r) })
    end

    def self.validate(data, collector)
      unless data.is_a?(Hash)
        collector.add("invalid_value", "$", "a rules config must be a JSON object with a \"rules\" array")
        return
      end
      collector.check_keys(data, "", allowed: TOP_LEVEL_KEYS, required: TOP_LEVEL_KEYS)
      return unless data.key?("rules")

      rules = data["rules"]
      unless rules.is_a?(Array)
        collector.add("invalid_value", "rules", "\"rules\" must be an array")
        return
      end
      rules.each_with_index { |rule, i| validate_rule(rule, "rules[#{i}]", collector) }
      check_duplicates(rules, "priority", "duplicate_priority", collector)
      check_duplicates(rules, "id", "duplicate_rule_id", collector)
    end

    def self.validate_rule(rule, path, collector)
      unless rule.is_a?(Hash)
        collector.add("invalid_value", path, "a rule must be a JSON object")
        return
      end
      collector.check_keys(rule, path, allowed: Rule::KEYS, required: Rule::KEYS)
      if rule.key?("id") && !Dispatch.non_empty_string?(rule["id"])
        collector.add("invalid_value", "#{path}.id", "id must be a non-empty string")
      end
      if rule.key?("priority") && !rule["priority"].is_a?(Integer)
        collector.add("invalid_value", "#{path}.priority", "priority must be an integer")
      end
      if rule.key?("queue") && !Dispatch.non_empty_string?(rule["queue"])
        collector.add("invalid_value", "#{path}.queue", "queue must be a non-empty string")
      end
      validate_skills(rule, path, collector) if rule.key?("required_skills")
      return unless rule.key?("conditions")

      if rule["conditions"].is_a?(Array)
        rule["conditions"].each_with_index do |condition, j|
          Condition.validate(condition, "#{path}.conditions[#{j}]", collector)
        end
      else
        collector.add("invalid_value", "#{path}.conditions", "conditions must be an array")
      end
    end

    def self.validate_skills(rule, path, collector)
      skills = rule["required_skills"]
      unless skills.is_a?(Array)
        collector.add("invalid_value", "#{path}.required_skills", "required_skills must be an array of strings")
        return
      end
      skills.each_with_index do |skill, k|
        next if Dispatch.non_empty_string?(skill)

        collector.add("invalid_value", "#{path}.required_skills[#{k}]", "a skill must be a non-empty string")
      end
    end

    # Reports each repeat at the later rule, e.g. rules[1].priority.
    def self.check_duplicates(rules, key, code, collector)
      first_seen = {}
      rules.each_with_index do |rule, i|
        next unless rule.is_a?(Hash) && rule.key?(key)

        value = rule[key]
        next if value.nil? || value.is_a?(Array) || value.is_a?(Hash)

        if first_seen.key?(value)
          collector.add(code, "rules[#{i}].#{key}", "#{key} #{value.inspect} is already used by rules[#{first_seen[value]}]")
        else
          first_seen[value] = i
        end
      end
    end

    def initialize(rules)
      @rules = rules.sort_by(&:priority).freeze
      freeze
    end

    # First matching rule by priority, or nil (fall-through to general_intake).
    def match(claim)
      rules.find { |rule| rule.matches?(claim) }
    end

    def find(rule_id)
      rules.find { |r| r.id == rule_id }
    end

    def queues
      rules.map(&:queue).uniq
    end

    def to_h
      { "rules" => rules.map(&:to_h) }
    end
  end
end
