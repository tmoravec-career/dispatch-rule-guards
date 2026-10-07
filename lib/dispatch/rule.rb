module Dispatch
  # A routing rule: all conditions must hold (AND). Lower priority is evaluated first (Q5).
  class Rule
    KEYS = %w[id priority conditions queue required_skills].freeze

    attr_reader :id, :priority, :conditions, :queue, :required_skills

    def initialize(id:, priority:, conditions:, queue:, required_skills:)
      @id = id
      @priority = priority
      @conditions = conditions.freeze
      @queue = queue
      @required_skills = required_skills.dup.freeze
      freeze
    end

    def self.from_h(hash)
      new(id: hash["id"], priority: hash["priority"], queue: hash["queue"],
          required_skills: hash["required_skills"],
          conditions: hash["conditions"].map { |c| Condition.from_h(c) })
    end

    def matches?(claim)
      conditions.all? { |c| c.matches?(claim) }
    end

    def to_h
      { "id" => id, "priority" => priority, "conditions" => conditions.map(&:to_h),
        "queue" => queue, "required_skills" => required_skills.dup }
    end
  end
end
