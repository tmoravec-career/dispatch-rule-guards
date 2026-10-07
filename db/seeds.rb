# Loads the shipped roster (config/adjusters.json, validated at boot) into the adjusters
# table. New adjusters start at the file's baseline open_claims (Q18). Re-running is safe:
# every listed adjuster's name, status, licensing, skills and capacity are refreshed from the
# file, but an existing adjuster keeps its live open_claims counter, so slots held by real
# claims are never freed (BUG-022). Demo claims: bin/rails dispatch:demo_claims.
roster = DispatchSettings.roster
Adjuster.load_roster!(roster)
puts "Seeded #{roster.adjusters.size} adjusters from #{Rails.configuration.x.dispatch.boot.adjusters_path}"
