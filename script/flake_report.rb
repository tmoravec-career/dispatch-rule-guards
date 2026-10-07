#!/usr/bin/env ruby
# Flake triage (PRODUCT_BRIEF.md "Quality bar"): merges JUnit XML from repeated runs of the same
# suite and labels every test.
#
#   ruby script/flake_report.rb [--markdown PATH] [--json PATH] RUN [RUN ...]
#
# Each RUN is one repetition: a directory (every *.xml below it, e.g. Cucumber's
# `--format junit --out DIR`, one file per feature) or a single JUnit XML file.
#
# Labels, over the runs in which the test actually ran (passed or failed):
#   stable  passed every time
#   flaky   passed at least once and failed at least once
#   broken  failed every time
# A test that was only ever skipped, or missing from every run, is listed as "not run" and
# gets no label. A test missing from some runs is labelled from the runs it appears in, and
# the report says it was missing.
#
# The Markdown report goes to standard output (and to --markdown PATH). Exit codes:
#   0 every labelled test is stable, 1 at least one flaky or broken test,
#   2 usage error, or a run with no readable JUnit XML.
# Plain Ruby; no bundle needed (rexml is a bundled gem of Ruby 3.3).

require "json"
require "optparse"
require "rexml/document"

module FlakeReport
  Outcome = Struct.new(:status, :message)
  Test = Struct.new(:id, :classname, :name, :outcomes) do
    def ran
      outcomes.compact.reject { |o| o.status == "skipped" }
    end

    def label
      statuses = ran.map(&:status)
      return nil if statuses.empty?
      return "stable" if statuses.all?("passed")
      return "broken" if statuses.all?("failed")

      "flaky"
    end

    def missing_runs
      outcomes.each_index.select { |i| outcomes[i].nil? }
    end

    def first_failure
      outcomes.compact.find { |o| o.status == "failed" }&.message
    end
  end

  class InputError < StandardError; end

  module_function

  # [[run_name, {test_id => [classname, name, Outcome]}], ...]
  def read_runs(paths)
    raise InputError, "give at least one run (a directory of JUnit XML or a JUnit XML file)" if paths.empty?

    paths.map do |path|
      files = File.directory?(path) ? Dir.glob(File.join(path, "**", "*.xml")).sort : [path]
      files.select! { |f| File.file?(f) }
      raise InputError, "#{path}: no JUnit XML found" if files.empty?

      cases = {}
      files.each { |file| read_file(file, cases) }
      [path, cases]
    end
  end

  def read_file(file, cases)
    doc = REXML::Document.new(File.read(file, mode: "rb").force_encoding(Encoding::UTF_8))
    raise InputError, "#{file}: not JUnit XML (no testsuite element)" unless doc.root && %w[testsuite testsuites].include?(doc.root.name)

    REXML::XPath.each(doc, "//testcase") do |tc|
      classname = tc.attributes["classname"].to_s
      name = tc.attributes["name"].to_s
      base = "#{classname} :: #{name}"
      # Two identical names in one run (e.g. outline rows) stay separate tests: #2, #3, ...
      id = base
      n = 1
      id = "#{base} ##{n += 1}" while cases.key?(id)
      cases[id] = [classname, name, outcome(tc)]
    end
  rescue REXML::ParseException => e
    raise InputError, "#{file}: malformed XML (#{e.message.lines.first.strip})"
  end

  def outcome(testcase)
    failure = testcase.elements["failure"] || testcase.elements["error"]
    if failure
      text = failure.attributes["message"].to_s
      text = failure.text.to_s.strip if text.empty?
      Outcome.new("failed", text.lines.first.to_s.strip[0, 200])
    elsif testcase.elements["skipped"]
      Outcome.new("skipped", nil)
    else
      Outcome.new("passed", nil)
    end
  end

  def merge(runs)
    tests = {}
    runs.each_with_index do |(_name, cases), i|
      cases.each do |id, (classname, name, result)|
        test = tests[id] ||= Test.new(id, classname, name, Array.new(runs.size))
        test.outcomes[i] = result
      end
    end
    tests.values.sort_by(&:id)
  end

  def summary(tests)
    counts = { "stable" => 0, "flaky" => 0, "broken" => 0, "not_run" => 0 }
    tests.each { |t| counts[t.label || "not_run"] += 1 }
    counts
  end

  def exit_code(tests)
    tests.any? { |t| %w[flaky broken].include?(t.label) } ? 1 : 0
  end

  def to_h(run_names, tests)
    {
      "runs" => run_names,
      "summary" => summary(tests),
      "tests" => tests.map do |t|
        { "id" => t.id, "classname" => t.classname, "name" => t.name, "label" => t.label || "not_run",
          "outcomes" => t.outcomes.map { |o| o&.status || "missing" }, "first_failure" => t.first_failure }
      end
    }
  end

  CELL = { "passed" => "pass", "failed" => "FAIL", "skipped" => "skip" }.freeze

  def to_markdown(run_names, tests)
    counts = summary(tests)
    verdict = exit_code(tests).zero? ? "PASS" : "FAIL"
    lines = ["## Flake report: #{verdict}", "",
             "#{run_names.size} run(s), #{tests.size} test(s): **#{counts['stable']} stable**, " \
             "**#{counts['flaky']} flaky**, **#{counts['broken']} broken**, #{counts['not_run']} not run.", ""]
    %w[flaky broken].each do |label|
      group = tests.select { |t| t.label == label }
      next if group.empty?

      lines << "### #{label.capitalize} (#{group.size})" << ""
      lines << "| Test | #{run_names.each_index.map { |i| "Run #{i + 1}" }.join(' | ')} | First failure |"
      lines << "|---|#{'---|' * run_names.size}---|"
      group.each do |t|
        cells = t.outcomes.map { |o| o ? CELL.fetch(o.status) : "missing" }
        lines << "| #{escape(t.id)} | #{cells.join(' | ')} | #{escape(t.first_failure.to_s)} |"
      end
      lines << ""
    end
    partial = tests.select { |t| t.label && !t.missing_runs.empty? }
    unless partial.empty?
      lines << "### Missing from some runs (#{partial.size})" << ""
      partial.each { |t| lines << "- #{escape(t.id)}: missing from run(s) #{t.missing_runs.map { |i| i + 1 }.join(', ')}" }
      lines << ""
    end
    lines << "Runs: #{run_names.each_with_index.map { |n, i| "#{i + 1} = `#{n}`" }.join(', ')}"
    lines.join("\n") + "\n"
  end

  def escape(text)
    text.gsub("|", "\\|").gsub(/\s*\n\s*/, " ")
  end

  def main(argv, out: $stdout, err: $stderr)
    options = {}
    parser = OptionParser.new do |o|
      o.banner = "Usage: ruby script/flake_report.rb [--markdown PATH] [--json PATH] RUN [RUN ...]"
      o.on("--markdown PATH") { |v| options[:markdown] = v }
      o.on("--json PATH") { |v| options[:json] = v }
    end
    paths = parser.parse(argv)
    runs = read_runs(paths)
    run_names = runs.map(&:first)
    tests = merge(runs)
    markdown = to_markdown(run_names, tests)
    out.binmode if out.respond_to?(:binmode)
    out.write(markdown)
    File.binwrite(options[:markdown], markdown) if options[:markdown]
    File.binwrite(options[:json], JSON.pretty_generate(to_h(run_names, tests)) + "\n") if options[:json]
    exit_code(tests)
  rescue InputError, OptionParser::ParseError, SystemCallError => e
    err.puts "flake_report: #{e.message}"
    2
  end
end

exit FlakeReport.main(ARGV) if $PROGRAM_NAME == __FILE__
