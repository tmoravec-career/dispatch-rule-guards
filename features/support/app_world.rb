# App-layer state for @api, @ui and @load scenarios. The shared setup steps (the dispatch
# rules, the adjuster roster, open-claim counters) check app_layer? and write to the
# running app instead of to plain-Ruby objects (STEP_GLOSSARY.md, "Scope rules").
module AppWorld
  def app_layer?
    @app_layer == true
  end

  # Makes `rules_hash` the app's active rules. Re-dispatch reads them at call time (Q19).
  def activate_rules!
    DispatchSettings.rules = Dispatch::RulesConfig.from_h(rules_hash)
  end

  # Replaces the app's roster with a validated one: the same validation as the engine layer.
  def load_app_roster!(roster)
    Adjuster.where.not(id: roster.adjusters.map(&:id)).delete_all
    Adjuster.load_roster!(roster)
  end

  def app_adjuster(id)
    Adjuster.find_by(id: id) or flunk("no adjuster #{id} in the app's roster")
  end

  # Dispatches through the app's own service (not HTTP), as "these claims have been dispatched in order:" does.
  def dispatch_in_app(claim_hashes)
    claim_hashes.map do |hash|
      attributes, errors = Dispatch::ClaimInput.validate(hash)
      assert_empty errors.map(&:to_a), "invalid claim in the table: #{hash.inspect}"
      ClaimDispatcher.new.create(attributes)
    end
  end
end

World(AppWorld)

Before("@api or @ui or @load") do
  @app_layer = true
end

# Every per-scenario app setting goes back to its boot value.
After("@api or @ui or @load") do
  DispatchSettings.reset!
  Clock.unfreeze
  ClaimDispatcher.after_candidate_selection = nil
end
