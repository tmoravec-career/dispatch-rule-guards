require "fileutils"
require "dispatch"

module Dispatch
  module Gate
    # bin/rule_diff: the rule-change impact gate (Q28, Q32).
    # Exit codes: 0 pass, 1 policy breach, 2 usage error or invalid input.
    class CLI
      EXIT_PASS = 0
      EXIT_BREACH = 1
      EXIT_ERROR = 2

      DEFAULT_ADJUSTERS = File.expand_path("../../../config/adjusters.json", __dir__)

      USAGE = <<~TEXT.freeze
        Usage: rule_diff --base FILE --proposed FILE [options]

        Replays claims through the base and proposed rules and reports what the change does.

        Claims (pick one):
          --claims FILE              replay this JSON array of claims, in order
          --seed N                   seeded generated claims (default 42)
          --claim-count N            number of generated claims (default 200)

        Roster:
          --adjusters FILE           starting roster (default: config/adjusters.json)

        Policy (the gate fails when an actual value is greater than the threshold):
          --max-new-unassigned N     default 0
          --max-reroute-pct P        default 10
          --max-probe-changes N      default 0

        Reports:
          --json-out PATH            write the JSON report
          --markdown-out PATH        write the Markdown report (default: standard output)

        Exit codes: 0 pass, 1 policy breach, 2 usage error or invalid input.
      TEXT

      VALUE_FLAGS = %w[--base --proposed --claims --seed --claim-count --adjusters --max-new-unassigned
                       --max-reroute-pct --max-probe-changes --json-out --markdown-out].freeze

      class UsageError < StandardError; end
      class InputError < StandardError; end

      def self.run(argv, stdout: $stdout, stderr: $stderr)
        new(argv, stdout: stdout, stderr: stderr).run
      end

      def initialize(argv, stdout:, stderr:)
        @argv = argv.dup
        @stdout = stdout
        @stderr = stderr
      end

      def run
        if @argv.include?("--help") || @argv.include?("-h")
          @stdout.print USAGE
          return EXIT_PASS
        end

        options = parse(@argv)
        policy = build_policy(options)
        base, proposed = load_rules(options)
        roster = load_roster(options)
        claims, seed = load_claims(options)

        report = Impact.new(base: base, proposed: proposed, claims: claims, roster: roster,
                            policy: policy, seed: seed).report
        write_reports(report, options)
        Impact.breached?(report) ? EXIT_BREACH : EXIT_PASS
      rescue UsageError => e
        @stderr.puts "rule_diff: #{e.message}", "", USAGE
        EXIT_ERROR
      rescue ConfigError, InputError => e
        @stderr.puts "rule_diff: #{e.message}"
        EXIT_ERROR
      rescue SystemCallError, IOError => e
        @stderr.puts "rule_diff: #{e.message}"
        EXIT_ERROR
      end

      private

      def parse(argv)
        options = {}
        args = argv.dup
        until args.empty?
          flag = args.shift
          raise UsageError, "unknown argument #{flag.inspect}" unless VALUE_FLAGS.include?(flag)
          raise UsageError, "#{flag} given more than once" if options.key?(flag)

          value = args.shift
          raise UsageError, "#{flag} needs a value" if value.nil? || value.start_with?("--")

          options[flag] = value
        end
        %w[--base --proposed].each { |f| raise UsageError, "#{f} is required" unless options.key?(f) }
        if options.key?("--claims") && (options.key?("--seed") || options.key?("--claim-count"))
          raise UsageError, "--claims cannot be combined with --seed or --claim-count"
        end
        options
      end

      def build_policy(options)
        Policy.new(max_new_unassigned: options.fetch("--max-new-unassigned", 0),
                   max_reroute_pct: options.fetch("--max-reroute-pct", 10),
                   max_probe_changes: options.fetch("--max-probe-changes", 0))
      rescue ArgumentError => e
        raise UsageError, e.message
      end

      # Validates both files before giving up, so one run reports every problem.
      def load_rules(options)
        errors = []
        configs = %w[--base --proposed].map do |flag|
          path = options[flag]
          raise UsageError, "#{flag} file not found: #{path}" unless File.file?(path)

          RulesConfig.load_file(path)
        rescue ConfigError => e
          errors << e
          nil
        end
        raise InputError, errors.map(&:message).join("\n") if errors.any?

        configs
      end

      def load_roster(options)
        path = options.fetch("--adjusters", DEFAULT_ADJUSTERS)
        raise UsageError, "--adjusters file not found: #{path}" unless File.file?(path)

        Roster.load_file(path)
      end

      def load_claims(options)
        if options.key?("--claims")
          path = options["--claims"]
          raise UsageError, "--claims file not found: #{path}" unless File.file?(path)

          return [Claim.load_file(path), nil]
        end
        seed = whole_number(options.fetch("--seed", ScenarioGenerator::DEFAULT_SEED.to_s), "--seed", min: 0)
        count = whole_number(options.fetch("--claim-count", ScenarioGenerator::DEFAULT_COUNT.to_s), "--claim-count", min: 1)
        [ScenarioGenerator.new(seed: seed, count: count).claims, seed]
      end

      def whole_number(text, flag, min:)
        value = text.match?(/\A\d+\z/) ? Integer(text, 10) : nil
        raise UsageError, "#{flag} must be a whole number >= #{min}, got #{text.inspect}" if value.nil? || value < min

        value
      end

      def write_reports(report, options)
        markdown = MarkdownReport.render(report)
        write(options["--json-out"], Impact.to_json(report)) if options.key?("--json-out")
        if options.key?("--markdown-out")
          write(options["--markdown-out"], markdown)
          breaches = report["policy_breaches"]
          @stdout.puts(breaches.empty? ? "rule_diff: PASS" : "rule_diff: FAIL (#{breaches.map { |b| b['policy'] }.join(', ')})")
        else
          @stdout.print markdown
        end
      end

      def write(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content, mode: "wb")
      end
    end
  end
end
