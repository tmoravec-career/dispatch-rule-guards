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

  test "tokens set at runtime are checked too" do
    assert_raises(ArgumentError) { DispatchSettings.api_tokens = { "a b" => "ops" } }
  end
end
