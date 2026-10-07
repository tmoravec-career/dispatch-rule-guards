# State for @engine scenarios: plain-Ruby rules, roster and results. No Rails, no DB.
# Phase 3 extends the shared setup steps to also make the data live in the app for
# @ui/@api scenarios (STEP_GLOSSARY.md, "Scope rules").
module EngineWorld
  attr_accessor :rules_hash

  def roster
    @roster or raise "no adjuster roster defined"
  end

  def roster=(roster)
    @roster = roster
  end

  def engine
    Dispatch::Engine.new(Dispatch::RulesConfig.from_h(rules_hash || { "rules" => [] }))
  end

  # Dispatches claim hashes in order, consuming capacity between them.
  def dispatch_claims(claim_hashes)
    @roster_before_dispatch = roster.copy
    current = engine
    @dispatched_claims = claim_hashes.map { |h| Dispatch::Claim.from_h(h) }
    @results = @dispatched_claims.map { |claim| current.dispatch(claim, roster) }
  end

  def results
    @results or raise "no claim has been dispatched"
  end

  def result
    results.last
  end

  def redispatch_against_fresh_roster
    raise "no claim has been dispatched" unless @dispatched_claims

    @second_result = engine.dispatch(@dispatched_claims.last, @roster_before_dispatch.copy)
  end

  def second_result
    @second_result or raise "the claim has not been dispatched a second time"
  end

  def load_rules_config(json_text)
    @loaded_config = nil
    @load_errors = nil
    @loaded_config = Dispatch::RulesConfig.parse(json_text)
  rescue Dispatch::ConfigError => e
    @load_errors = e.errors
  end

  def loaded_config
    @loaded_config
  end

  def load_errors
    @load_errors or flunk("expected the rules config to be rejected, but it loaded")
  end
end

World(EngineWorld)
