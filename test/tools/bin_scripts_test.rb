require_relative "../test_helper"
require "open3"

# BUG-020: every script in bin/ must start on Linux CI and in Docker, not only on Windows.
# That needs a portable shebang (no "ruby.exe"), LF line endings and the executable bit
# recorded in git.
class BinScriptsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PORTABLE_SHEBANG = "#!/usr/bin/env ruby".freeze

  def tracked_bin_files
    out, err, status = Open3.capture3("git", "ls-files", "-s", "bin", chdir: ROOT)
    skip "git is not available: #{err}" unless status.success?

    # "<mode> <object> <stage>\t<path>"
    out.lines.map { |line| line.chomp.split("\t", 2).then { |meta, path| [path, meta.split(" ").first] } }
  end

  def test_bin_has_scripts
    refute_empty tracked_bin_files
  end

  def test_every_bin_script_has_a_portable_shebang
    tracked_bin_files.each do |path, _mode|
      first_line = File.open(File.join(ROOT, path), "rb", &:gets).to_s
      assert_equal "#{PORTABLE_SHEBANG}\n", first_line, "#{path} must start with #{PORTABLE_SHEBANG} and an LF"
    end
  end

  def test_every_bin_script_is_executable_in_git
    tracked_bin_files.each do |path, mode|
      assert_equal "100755", mode, "#{path} must be committed as 100755 (git update-index --chmod=+x #{path})"
    end
  end
end
