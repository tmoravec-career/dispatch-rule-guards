require_relative "../app_helper"

# BUG-019: errors that reach config.exceptions_app get a minimal HTML page in the browser
# UI and keep the JSON errors body under /api. Each request here asks for production-style
# error handling (no debug page, every exception shown through exceptions_app).
class ErrorPagesTest < ActionDispatch::IntegrationTest
  include AppTestHelpers

  PRODUCTION_ERRORS = { "action_dispatch.show_exceptions" => :all,
                        "action_dispatch.show_detailed_exceptions" => false }.freeze

  # The app's env_config overrides per-request env, so switch it there for each test.
  def setup
    super
    @env_config = Rails.application.env_config.slice(*PRODUCTION_ERRORS.keys)
    Rails.application.env_config.merge!(PRODUCTION_ERRORS)
  end

  def teardown
    Rails.application.env_config.merge!(@env_config)
    super
  end

  def assert_html_error_page(status)
    assert_response status
    assert_equal "text/html", response.media_type
    assert_includes response.body, "<h1>#{status} "
    assert_includes response.body, 'href="/claims"'
    refute_includes response.body, '"errors"'
  end

  test "an unknown page is an HTML 404" do
    get "/no-such-page"
    assert_html_error_page(404)
  end

  test "a form posted with an invalid CSRF token gets an HTML 422 page" do
    protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post "/claims", params: { authenticity_token: "expired", claim: { claim_number: "CLM-E1" } }
    assert_html_error_page(422)
    assert_includes response.body, "reload the page"
    refute Claim.exists?(claim_number: "CLM-E1")
  ensure
    ActionController::Base.allow_forgery_protection = protection
  end

  test "an unhandled error on a UI page gets an HTML 500 page without details" do
    Adjuster.stub(:order, ->(*) { raise "boom: secret detail" }) do
      get "/adjusters"
    end
    assert_html_error_page(500)
    refute_includes response.body, "secret detail"
  end

  test "under /api the error body stays JSON" do
    env = Rack::MockRequest.env_for("/500", "action_dispatch.original_path" => "/api/claims")
    status, headers, body = ErrorsController.action(:show).call(env)
    assert_equal 500, status
    assert_match %r{\Aapplication/json}, headers["content-type"]
    assert_equal({ "errors" => [{ "field" => nil, "code" => "internal_server_error" }] }, JSON.parse(body.each.to_a.join))
  end
end
