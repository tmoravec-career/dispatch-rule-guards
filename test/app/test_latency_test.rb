require_relative "../app_helper"
require "open3"

# DISPATCH_TEST_LATENCY_MS: the test-only seam behind "the app adds {int} ms of latency to
# every API response" (STEP_GLOSSARY.md section 9). Off by default, applied to every API
# response (even a 401), and refused outside the test environment.
class TestLatencyTest < ActionDispatch::IntegrationTest
  include AppTestHelpers

  ROOT = File.expand_path("../..", __dir__)

  def boot(env)
    Open3.capture3({ "RAILS_ENV" => "test" }.merge(env), RbConfig.ruby, File.join(ROOT, "bin", "rails"), "runner",
                   "puts DispatchSettings.test_latency_ms", chdir: ROOT)
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  test "there is no added latency by default" do
    assert_equal 0, DispatchSettings.test_latency_ms
  end

  test "the setting delays every API response, authenticated or not" do
    DispatchSettings.stub(:test_latency_ms, 300) do
      assert_operator timed { get "/api/claims", headers: { "Authorization" => "Bearer #{OPS}" } }, :>=, 0.3
      assert_response :ok
      assert_operator timed { get "/api/claims" }, :>=, 0.3
      assert_response :unauthorized
    end
  end

  test "the setting is read at boot, validated, and refused outside the test environment" do
    out, err, status = boot("DISPATCH_TEST_LATENCY_MS" => "500")
    assert status.success?, err
    assert_equal "500", out.strip

    _, err, status = boot("DISPATCH_TEST_LATENCY_MS" => "-5")
    refute status.success?
    assert_includes err, "DISPATCH_TEST_LATENCY_MS must be a whole number"

    _, err, status = boot("RAILS_ENV" => "production", "SECRET_KEY_BASE" => "a" * 128, "DISPATCH_TEST_LATENCY_MS" => "500")
    refute status.success?
    assert_includes err, "DISPATCH_TEST_LATENCY_MS is a test-only setting and is refused in production"

    _, err, status = boot("RAILS_ENV" => "development", "DISPATCH_TEST_LATENCY_MS" => "500")
    refute status.success?
    assert_includes err, "DISPATCH_TEST_LATENCY_MS is a test-only setting and is refused in development"
  end
end
