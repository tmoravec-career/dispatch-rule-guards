namespace :dispatch do
  desc "Fail (exit 1) if any adjuster, active or not, has open_claims > capacity"
  task capacity_audit: :environment do
    exit CapacityAudit.new.run
  end

  desc "Dispatch realistic demo claims from the engine's seeded generator: COUNT=50 SEED=42"
  task demo_claims: :environment do
    count = Integer(ENV.fetch("COUNT", "50"), 10)
    seed = Integer(ENV.fetch("SEED", Dispatch::ScenarioGenerator::DEFAULT_SEED.to_s), 10)
    claims = Dispatch::ScenarioGenerator.new(seed: seed, count: count).claims
    dispatcher = ClaimDispatcher.new
    created = claims.count do |claim|
      next false if Claim.exists?(claim_number: claim.claim_number)

      dispatcher.create(claim.to_h)
      true
    end
    by_status = Claim.where(claim_number: claims.map(&:claim_number)).group(:status).count
    puts "Dispatched #{created} new demo claims (seed #{seed}); #{by_status.sort.map { |s, n| "#{n} #{s}" }.join(', ')}"
  end
end
