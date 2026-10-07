require "open3"
require "rbconfig"
require "shellwords"

# Runs bin/rule_diff as a subprocess, exactly as CI does: plain `ruby -Ilib`, no bundle,
# with the scenario's temp dir as the working directory (STEP_GLOSSARY.md section 8).
module GateRunner
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin", "rule_diff")
  LIB = File.join(ROOT, "lib")

  GateRun = Struct.new(:args, :status, :stdout, :stderr, :json_path, :markdown_path, :loaded_features_path,
                       keyword_init: true) do
    def json_report
      JSON.parse(File.read(json_path))
    end

    def markdown_report
      File.read(markdown_path)
    end
  end

  def gate_dir
    @gate_dir ||= Dir.mktmpdir("rule_diff")
  end

  def gate_file(name)
    File.join(gate_dir, name)
  end

  def write_gate_file(name, content)
    File.binwrite(gate_file(name), content.is_a?(String) ? content : "#{JSON.pretty_generate(content)}\n")
  end

  def read_gate_rules(name)
    JSON.parse(File.read(gate_file(name)))
  end

  def gate_env
    @gate_env ||= {}
  end

  attr_accessor :last_claims_file, :last_adjusters_file

  def gate_runs
    @gate_runs ||= []
  end

  # The run report assertions read: the most recent one, or run 1 after "twice".
  def report_run
    @report_run or raise "the impact gate has not been run"
  end

  def last_run
    gate_runs.last or raise "the impact gate has not been run"
  end

  # `reports_to` names a subdirectory for --json-out/--markdown-out, or nil for none.
  def run_gate(args, reports_to: "out")
    args = args.dup
    json_path = markdown_path = nil
    if reports_to
      json_path = gate_file(File.join(reports_to, "report.json"))
      markdown_path = gate_file(File.join(reports_to, "report.md"))
      args += ["--json-out", "#{reports_to}/report.json", "--markdown-out", "#{reports_to}/report.md"]
    end
    loaded = gate_file("loaded_features-#{gate_runs.size + 1}.txt")
    env = { "RULE_DIFF_LOADED_FEATURES_OUT" => loaded }.merge(gate_env)
    stdout, stderr, status = without_bundler do
      Open3.capture3(env, RbConfig.ruby, "-I", LIB, BIN, *args, chdir: gate_dir)
    end
    run = GateRun.new(args: args, status: status.exitstatus, stdout: stdout, stderr: stderr,
                      json_path: json_path, markdown_path: markdown_path, loaded_features_path: loaded)
    gate_runs << run
    @report_run = run
  end

  # "comparing A to B": the most recently defined claims and adjusters files are passed too.
  def comparison_args(base, proposed)
    args = ["--base", base, "--proposed", proposed]
    args += ["--claims", last_claims_file] if last_claims_file
    args += ["--adjusters", last_adjusters_file] if last_adjusters_file
    args
  end

  def split_args(text)
    Shellwords.split(text)
  end

  # The gate must work without the bundle, so don't let `bundle exec` leak into the child.
  def without_bundler(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : block.call
  end
end

World(GateRunner)

After do
  FileUtils.rm_rf(@gate_dir) if @gate_dir
end
