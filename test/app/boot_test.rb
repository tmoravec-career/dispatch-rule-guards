require_relative "../app_helper"
require "open3"

# Q9: the app refuses to boot on invalid config. Each case boots a real subprocess.
class BootTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  def boot(env)
    Open3.capture3({ "RAILS_ENV" => "test" }.merge(env), RbConfig.ruby, File.join(ROOT, "bin", "rails"), "runner",
                   "puts 'BOOTED'", chdir: ROOT)
  end

  def with_file(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, content)
      yield path
    end
  end

  test "the shipped config boots" do
    out, err, status = boot({})
    assert status.success?, err
    assert_includes out, "BOOTED"
  end

  test "an invalid rules file stops the boot and lists every error" do
    rules = '{"rules":[{"id":"a","priority":1,"queue":"q","required_skills":[],' \
            '"conditions":[{"field":"vehicle_val","op":"gte","value":"100000"}],"enforce_licensing":false}]}'
    with_file(rules) do |path|
      out, err, status = boot("DISPATCH_RULES_PATH" => path)
      refute status.success?
      refute_includes out, "BOOTED"
      %w[unknown_field non_numeric_threshold].each { |code| assert_includes err, code }
      assert_includes err, "rules[0].enforce_licensing"
    end
  end

  test "an invalid roster file stops the boot" do
    with_file('{"adjusters":[{"id":"ADJ-1","name":"A","active":true,"licensed_states":["TX"],"skills":[],' \
              '"capacity":1,"open_claims":2}]}') do |path|
      _, err, status = boot("DISPATCH_ADJUSTERS_PATH" => path)
      refute status.success?
      assert_includes err, "exceeds capacity"
    end
  end

  # BUG-021: the web UI's session cookie (and its CSRF token) needs SECRET_KEY_BASE.
  test "production refuses to boot without SECRET_KEY_BASE and names the variable" do
    [nil, "", "  "].each do |value|
      out, err, status = boot("RAILS_ENV" => "production", "SECRET_KEY_BASE" => value)
      refute status.success?, "booted with SECRET_KEY_BASE=#{value.inspect}"
      refute_includes out, "BOOTED"
      assert_includes err, "refusing to boot in production: SECRET_KEY_BASE is not set"
    end
  end

  test "production boots with SECRET_KEY_BASE set" do
    out, err, status = boot("RAILS_ENV" => "production", "SECRET_KEY_BASE" => "a" * 128)
    assert status.success?, err
    assert_includes out, "BOOTED"
  end

  test "an unknown token role or an unsigned webhook stops the boot" do
    _, err, status = boot("DISPATCH_API_TOKENS" => "t1:admin")
    refute status.success?
    assert_includes err, "unknown role"

    _, err, status = boot("DISPATCH_WEBHOOK_URL" => "http://hooks.test/in")
    refute status.success?
    assert_includes err, "DISPATCH_WEBHOOK_SECRET"
  end
end
