# STEP_GLOSSARY.md section 4: rules config validation.

When("I load a rules config:") do |doc_string|
  load_rules_config(doc_string)
end

When("I load a rules config with a single rule whose conditions are:") do |doc_string|
  load_rules_config(%({"rules":[{"id":"r1","priority":1,"queue":"q1","required_skills":[],"conditions":#{doc_string}}]}))
end

Then("the rules config loads with {int} rules") do |count|
  assert_nil @load_errors, -> { "expected the config to load, got #{@load_errors.map(&:to_s)}" }
  assert_equal count, loaded_config.rules.size
end

Then("the rules config is rejected with error {string}") do |code|
  assert_includes load_errors.map(&:code), code, -> { load_errors.map(&:to_s).inspect }
  @asserted_error_code = code
end

Then("the error points at {string}") do |path|
  paths = load_errors.select { |e| e.code == @asserted_error_code }.map(&:path)
  assert_includes paths, path, "#{@asserted_error_code} errors point at #{paths.inspect}"
end

Then("the rules config is rejected with errors:") do |table|
  expected = table.hashes.map { |row| [row["error"], row["path"]] }.sort
  assert_equal expected, load_errors.map { |e| [e.code, e.path] }.sort
end

Then("no rules are loaded") do
  assert_nil loaded_config
end
