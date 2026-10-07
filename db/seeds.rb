# Loads the shipped roster (config/adjusters.json, validated at boot) into the adjusters
# table, including each adjuster's baseline open_claims (Q18). Idempotent: re-running
# resets every listed adjuster to the file's values. Demo claims: bin/rails dispatch:demo_claims.
roster = DispatchSettings.roster
Adjuster.load_roster!(roster)
puts "Seeded #{roster.adjusters.size} adjusters from #{Rails.configuration.x.dispatch.boot.adjusters_path}"
