require_relative "../app_helper"

# DispatchSettings.load! is what boot runs (Q9, Q57). Called in-process here with a given
# environment; test/app/boot_test.rb proves a real boot stops on the same errors.
class DispatchSettingsTest < ActiveSupport::TestCase
  include AppTestHelpers

  def teardown
    DispatchSettings.load! # back to the real environment's settings
    super
  end

  def refused(env)
    assert_raises(DispatchSettings::InvalidConfig) { DispatchSettings.load!(env) }.message
  end

  test "tokens: space around commas is fine" do
    DispatchSettings.load!("DISPATCH_API_TOKENS" => "ops-1:ops , adj-1: adjuster")
    assert_equal({ "ops-1" => "ops", "adj-1" => "adjuster" }, DispatchSettings.api_tokens)
  end

  test "tokens: a duplicate refuses to boot without echoing the token" do
    message = refused("DISPATCH_API_TOKENS" => "secret-1:ops,secret-1:adjuster")
    assert_includes message, "entry 2: the token is listed more than once"
    refute_includes message, "secret-1"
  end

  test "tokens: whitespace inside or around a token refuses to boot" do
    ["ops 1:ops", "ops-1 :ops", "ops\t1:ops"].each do |value|
      assert_includes refused("DISPATCH_API_TOKENS" => value), "contains whitespace", value.inspect
    end
  end

  test "tokens: unknown roles and malformed entries refuse to boot" do
    assert_includes refused("DISPATCH_API_TOKENS" => "t1:admin"), "unknown role"
    assert_includes refused("DISPATCH_API_TOKENS" => "t1"), "expected token:role"
    assert_includes refused("DISPATCH_API_TOKENS" => ":ops"), "expected token:role"
  end

  test "the webhook URL must be an absolute http or https URL (Q57)" do
    ["hooks.test/in", "/in", "ftp://hooks.test/in", "http://", "http:// bad", "mailto:a@b.test"].each do |url|
      message = refused("DISPATCH_WEBHOOK_URL" => url, "DISPATCH_WEBHOOK_SECRET" => "s")
      assert_includes message, "absolute http or https URL", url
    end
    %w[http://hooks.test/in https://hooks.test:8443/in].each do |url|
      DispatchSettings.load!("DISPATCH_WEBHOOK_URL" => url, "DISPATCH_WEBHOOK_SECRET" => "s")
      assert_equal url, DispatchSettings.webhook_url
    end
  end

  test "a missing rules or roster file gets the standard refusal (Q57)" do
    %w[DISPATCH_RULES_PATH DISPATCH_ADJUSTERS_PATH].each do |name|
      message = refused(name => File.join(Dir.tmpdir, "no-such-dispatch-config.json"))
      assert_match(/\Arefusing to boot with invalid dispatch config \(Q9\):\n.*no-such-dispatch-config\.json/m, message, name)
    end
  end

  test "every refusal starts with the standard message" do
    assert_match(/\Arefusing to boot/, refused("DISPATCH_API_TOKENS" => "t1:admin"))
    assert_match(/\Arefusing to boot/, refused("DISPATCH_RATE_LIMIT" => "lots"))
  end

  test "tokens set at runtime are checked too" do
    assert_raises(ArgumentError) { DispatchSettings.api_tokens = { "a b" => "ops" } }
  end

  # BUG-026: the per-scenario overrides can't swap live settings outside test.
  test "the override setters raise outside the test environment and change nothing" do
    rules = DispatchSettings.rules
    tokens = DispatchSettings.api_tokens
    limiter = DispatchSettings.rate_limiter
    empty_rules = Dispatch::RulesConfig.from_h({ "rules" => [] })
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      {
        "rules=" => -> { DispatchSettings.rules = empty_rules },
        "api_tokens=" => -> { DispatchSettings.api_tokens = { "x" => "ops" } },
        "webhook_url=" => -> { DispatchSettings.webhook_url = "http://hooks.test/in" },
        "webhook_secret=" => -> { DispatchSettings.webhook_secret = "s" },
        "configure_rate_limit" => -> { DispatchSettings.configure_rate_limit(limit: 1, window_seconds: 1) }
      }.each do |setter, call|
        error = assert_raises(ArgumentError, setter) { call.call }
        assert_includes error.message, "test-only", setter
      end
      assert_same rules, DispatchSettings.rules
      assert_equal tokens, DispatchSettings.api_tokens
      assert_nil DispatchSettings.webhook_url
      assert_same limiter, DispatchSettings.rate_limiter

      # Boot still installs its own values through reset!.
      DispatchSettings.reset!
      refute_same limiter, DispatchSettings.rate_limiter
    end
  end
end
