module Dispatch
  # Seeded generator of realistic claims for the gate's replay and for demo data.
  # The only source of randomness in the engine; the same seed and count always
  # give the same claims in the same order (Q31).
  class ScenarioGenerator
    DEFAULT_SEED = 42
    DEFAULT_COUNT = 200

    # Weighted by rough claim volume; includes states no seed adjuster is licensed in.
    STATES = { "TX" => 18, "FL" => 16, "CA" => 16, "NY" => 10, "LA" => 7, "AZ" => 7, "GA" => 7,
               "NV" => 5, "NJ" => 5, "CO" => 3, "WY" => 2 }.freeze
    CAT_STATES = %w[TX FL LA].freeze

    attr_reader :seed, :count

    def initialize(seed: DEFAULT_SEED, count: DEFAULT_COUNT)
      @seed = seed
      @count = count
    end

    def claims
      rng = Random.new(seed)
      Array.new(count) { |i| build(rng, format("SIM-%04d", i + 1)) }
    end

    private

    def build(rng, number)
      lob = weighted(rng, "auto" => 55, "property" => 35, "liability" => 10)
      send("#{lob}_claim", rng, number)
    end

    def auto_claim(rng, number)
      loss = weighted(rng, small: 25, medium: 50, large: 25)
      estimated = { small: between(rng, 500, 4_999, 100), medium: between(rng, 5_000, 25_000, 100),
                    large: between(rng, 25_100, 120_000, 500) }.fetch(loss)
      vehicle = rng.rand < 0.2 ? between(rng, 60_000, 180_000, 1_000) : between(rng, 8_000, 59_000, 500)
      Claim.new(claim_number: number, line_of_business: "auto", estimated_loss: estimated,
                vehicle_value: vehicle, cat_event: false, loss_state: state(rng))
    end

    def property_claim(rng, number)
      cat = rng.rand < 0.3
      Claim.new(claim_number: number, line_of_business: "property",
                estimated_loss: cat ? between(rng, 10_000, 150_000, 500) : between(rng, 2_000, 90_000, 500),
                vehicle_value: nil, cat_event: cat,
                loss_state: cat ? CAT_STATES[rng.rand(CAT_STATES.size)] : state(rng))
    end

    def liability_claim(rng, number)
      Claim.new(claim_number: number, line_of_business: "liability", estimated_loss: between(rng, 5_000, 100_000, 500),
                vehicle_value: nil, cat_event: false, loss_state: state(rng))
    end

    def state(rng)
      weighted(rng, STATES)
    end

    # A multiple of `step` in [low, high].
    def between(rng, low, high, step)
      low + (rng.rand(((high - low) / step) + 1) * step)
    end

    def weighted(rng, weights)
      pick = rng.rand(weights.values.sum)
      weights.each do |key, weight|
        return key if pick < weight

        pick -= weight
      end
    end
  end
end
