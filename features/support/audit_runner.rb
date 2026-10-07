require "open3"
require "rbconfig"

# Runs bin/capacity_audit as a subprocess against the scenario's (file-based, committed)
# test database, as the k6 jobs will (STEP_GLOSSARY.md section 9).
module AuditRunner
  ROOT = File.expand_path("../..", __dir__)
  AuditRun = Struct.new(:status, :stdout, :stderr) do
    def violations
      stdout.scan(/^VIOLATION adjuster=(\S+) open_claims=(\d+) capacity=(\d+)$/)
    end
  end

  def run_capacity_audit
    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, RbConfig.ruby, File.join(ROOT, "bin", "capacity_audit"),
                                            chdir: ROOT)
    @audit_run = AuditRun.new(status.exitstatus, stdout, stderr)
  end

  def audit_run
    @audit_run or flunk("the capacity audit has not been run")
  end
end

World(AuditRunner)
