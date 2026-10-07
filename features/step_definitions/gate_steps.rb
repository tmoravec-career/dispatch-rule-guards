# STEP_GLOSSARY.md section 8: the rule-change impact gate CLI, run as a subprocess.

# --- input files -------------------------------------------------------------

Given("an adjusters file {string} with the adjuster roster:") do |name, table|
  write_gate_file(name, Tables.roster_hash(table))
  self.last_adjusters_file = name
end

Given("a rules file {string} with the dispatch rules:") do |name, table|
  write_gate_file(name, Tables.rules_hash(table))
end

Given("a claims file {string} with the claims:") do |name, table|
  write_gate_file(name, Tables.claim_hashes(table))
  self.last_claims_file = name
end

Given("a rules file {string} copied from {string}") do |name, source|
  write_gate_file(name, read_gate_rules(source))
end

Given("a rules file {string} copied from {string} with these condition changes:") do |name, source, table|
  rules = read_gate_rules(source)
  table.hashes.each { |row| Tables.replace_condition(rules, row.fetch("rule"), row.fetch("condition")) }
  write_gate_file(name, rules)
end

Given("a rules file {string} copied from {string} with the added rule:") do |name, source, table|
  rules = read_gate_rules(source)
  added = Tables.rules_hash(table)["rules"]
  assert_equal 1, added.size, "this step adds exactly one rule"
  rules["rules"].concat(added)
  write_gate_file(name, rules)
end

Given("a rules file {string} copied from {string} without rule {string}") do |name, source, rule_id|
  rules = read_gate_rules(source)
  before = rules["rules"].size
  rules["rules"].reject! { |r| r["id"] == rule_id }
  assert_equal before - 1, rules["rules"].size, "no rule #{rule_id.inspect} in #{source}"
  write_gate_file(name, rules)
end

Given("a rules file {string} containing:") do |name, doc_string|
  write_gate_file(name, doc_string)
end

Given("the environment has no database configured") do
  # nil unsets the variable for the subprocess. The gate has no other DB config to point
  # elsewhere: it never loads one.
  gate_env["DATABASE_URL"] = nil
end

# --- running -----------------------------------------------------------------

When("I run the impact gate comparing {string} to {string}") do |base, proposed|
  run_gate(comparison_args(base, proposed))
end

When("I run the impact gate comparing {string} to {string} with flags {string}") do |base, proposed, flags|
  run_gate(comparison_args(base, proposed) + split_args(flags))
end

When("I run the impact gate with arguments {string}") do |arguments|
  run_gate(split_args(arguments))
end

When("I run the impact gate with exactly the arguments {string}") do |arguments|
  run_gate(split_args(arguments), reports_to: nil)
end

When("I run the impact gate twice with arguments {string}") do |arguments|
  first = run_gate(split_args(arguments), reports_to: "run1")
  run_gate(split_args(arguments), reports_to: "run2")
  @report_run = first
end

# --- outcome -----------------------------------------------------------------

Then("the gate exits with status {int}") do |status|
  run = last_run
  assert_equal status, run.status, "stdout:\n#{run.stdout}\nstderr:\n#{run.stderr}"
end

Then("the gate reports these policy breaches:") do |table|
  expected = table.hashes.map { |row| [row["policy"], Rational(row["threshold"]), Rational(row["actual"])] }
  actual = report_run.json_report["policy_breaches"].map do |b|
    [b["policy"], Rational(b["threshold"].to_s), Rational(b["actual"].to_s)]
  end
  assert_equal expected.sort_by(&:first), actual.sort_by(&:first)
end

Then("the gate reports no policy breaches") do
  assert_equal [], report_run.json_report["policy_breaches"]
end

Then("the report lists these newly unassigned claims:") do |table|
  assert_same_rows(report_run.json_report["newly_unassigned"], table)
end

Then("the report lists these newly assigned claims:") do |table|
  assert_same_rows(report_run.json_report["newly_assigned"], table)
end

Then("the report lists these queue changes:") do |table|
  assert_same_rows(report_run.json_report["queue_changes"], table)
end

Then("the report lists these rerouted claims:") do |table|
  assert_same_rows(report_run.json_report["rerouted"], table)
end

Then("the report lists these boundary probe changes, among others:") do |table|
  assert_rows_included(report_run.json_report["boundary_probe_changes"], table)
end

Then("the report lists no boundary probe change for:") do |table|
  changes = project(report_run.json_report["boundary_probe_changes"], %w[field value])
  table_rows(table).each do |field, value|
    refute_includes changes, [field, value], "unexpected boundary probe change at #{field} #{value}"
  end
end

Then("the report includes boundary probes for:") do |table|
  probes = project(report_run.json_report["boundary_probes"], %w[field value])
  table.hashes.each do |row|
    row.fetch("values").split(",").map(&:strip).each do |value|
      assert_includes probes, [row.fetch("field"), value], "no boundary probe at #{row['field']} #{value}"
    end
  end
end

Then("the JSON report at {string} is {json}") do |path, expected|
  actual = json_at(report_run.json_report, path)
  assert json_typed_equal?(actual, expected), "expected #{path} to be #{expected.inspect} (#{expected.class}), " \
                                              "got #{actual.inspect} (#{actual.class})"
end

Then("the Markdown report has these sections in order:") do |table|
  headings = report_run.markdown_report.scan(/^## (.+?)\s*$/).flatten
  assert_equal table.raw.drop(1).map(&:first), headings
end

Then("the Markdown report mentions {string}") do |text|
  assert_includes report_run.markdown_report, text
end

Then("the gate did not load the web application") do
  path = last_run.loaded_features_path
  assert File.exist?(path), "the gate did not record its loaded features"
  features = File.read(path).lines.map(&:strip)
  refute_empty features
  web = features.grep(%r{[/\\](rails|railties|active_?record|action_?pack|action_?view|active_?support|sqlite3)[^/\\]*[/\\]|[/\\]rails\.rb\z}i)
  assert_empty web, "the gate loaded web-app code:\n#{web.join("\n")}"
end

Then("both runs exit with the same status") do
  first, second = gate_runs.last(2)
  assert_equal first.status, second.status
end

Then("both JSON reports are identical") do
  first, second = gate_runs.last(2)
  assert_equal File.binread(first.json_path), File.binread(second.json_path)
end

Then("the gate's error output mentions {string}") do |text|
  assert_includes last_run.stderr, text
end

Then("the gate's standard output mentions {string}") do |text|
  assert_includes last_run.stdout, text
end

Then("no report is written") do
  run = last_run
  [run.json_path, run.markdown_path].compact.each do |path|
    refute File.exist?(path), "#{path} was written"
  end
end
