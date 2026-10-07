module Dispatch
  # Routing decision: the first matching rule, or general_intake.
  Routing = Struct.new(:queue, :rule) do
    def rule_id
      rule&.id
    end

    def required_skills
      rule ? rule.required_skills : []
    end
  end

  # Route -> qualify -> select. Deterministic: lowest utilization wins, ties broken
  # by adjuster ID (Q16).
  #
  # Two ways to use it:
  # - dispatch(claim, roster): decide and take the slot on an in-memory Roster.
  # - decide(claim, roster, exclude:): decide without mutating anything. A caller that
  #   claims slots elsewhere (the app's atomic conditional UPDATE, Q37) re-decides after
  #   losing a race, passing the adjusters that filled up in `exclude`.
  class Engine
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def route(claim)
      rule = config.match(claim)
      Routing.new(rule ? rule.queue : GENERAL_INTAKE, rule)
    end

    # Active, licensed in the loss state and holding every required skill. Licensing
    # is always enforced here and is not configurable (Q11).
    def qualified?(adjuster, claim, required_skills)
      adjuster.active && adjuster.licensed_in?(claim.loss_state) && adjuster.skilled_for?(required_skills)
    end

    def qualified(claim, roster, routing = route(claim))
      roster.adjusters.select { |a| qualified?(a, claim, routing.required_skills) }
    end

    # Qualified adjusters with room, best first. Excluded IDs are treated as full. `exclude`
    # may be an Array, a Set, a single ID or nil; IDs match whole, never as substrings.
    # `pool` lets a caller that already has the qualified list skip recomputing it.
    def candidates(claim, roster, exclude: [], routing: route(claim), pool: nil)
      excluded = Array(exclude)
      (pool || qualified(claim, roster, routing))
        .reject { |a| a.full? || excluded.include?(a.id) }
        .sort_by { |a| [a.utilization, a.id] }
    end

    def decide(claim, roster, exclude: [])
      routing = route(claim)
      qualified = qualified(claim, roster, routing)
      best = candidates(claim, roster, exclude: exclude, routing: routing, pool: qualified).first
      reason_code =
        if best then Result::ASSIGNED
        elsif qualified.empty? then Result::NO_QUALIFIED_ADJUSTER
        else Result::QUALIFIED_ADJUSTERS_AT_CAPACITY
        end
      Result.new(claim_number: claim.claim_number, queue: routing.queue, matched_rule: routing.rule_id,
                 adjuster_id: best&.id, reason_code: reason_code,
                 reason: explain(claim, routing, reason_code, best, qualified.size))
    end

    def dispatch(claim, roster)
      result = decide(claim, roster)
      roster.assign!(result.adjuster_id) if result.assigned?
      result
    end

    private

    def explain(claim, routing, reason_code, adjuster, qualified_count)
      matched = routing.rule ? "Matched rule #{routing.rule.id} (queue #{routing.queue})." :
                               "No rule matched; fell through to #{GENERAL_INTAKE}."
      skills = routing.required_skills.empty? ? "no particular skills" : "skills #{routing.required_skills.join(', ')}"
      outcome =
        case reason_code
        when Result::ASSIGNED
          "Assigned to #{adjuster.id} (#{adjuster.name}), the least utilized of the qualified adjusters with capacity " \
            "(#{adjuster.open_claims}/#{adjuster.capacity} open)."
        when Result::NO_QUALIFIED_ADJUSTER
          "No active adjuster is licensed in #{claim.loss_state} with #{skills}."
        else
          "All #{qualified_count} qualified adjuster#{'s' unless qualified_count == 1} licensed in #{claim.loss_state} " \
            "with #{skills} #{qualified_count == 1 ? 'is' : 'are'} at capacity."
        end
      "#{matched} #{outcome}"
    end
  end
end
