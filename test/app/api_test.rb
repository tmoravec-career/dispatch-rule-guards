require_relative "../app_helper"

# Request-level checks the features don't spell out: auth before routing, JSON on every
# path, and the error body shape (Q20, Q39, Q44).
class ApiTest < ActionDispatch::IntegrationTest
  include AppTestHelpers

  def auth(token = OPS)
    { "Authorization" => "Bearer #{token}" }
  end

  def errors
    response.parsed_body.fetch("errors")
  end

  test "an unrouted API path is authenticated first, then a JSON 404" do
    get "/api/nothing/here"
    assert_response :unauthorized
    assert_equal [{ "field" => nil, "code" => "unauthorized" }], errors

    delete "/api/claims/CLM-1", headers: auth
    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal "not_found", errors.first["code"]
  end

  test "malformed JSON on create is a 400 even though Rails would parse JSON params itself" do
    post "/api/claims", params: '{"claim_number": ', headers: auth.merge("Content-Type" => "application/json")
    assert_response :bad_request
    assert_equal "malformed_json", errors.first["code"]
  end

  test "a JSON body that is not an object is a 422" do
    post "/api/claims", params: "[1, 2]", headers: auth.merge("Content-Type" => "application/json; charset=utf-8")
    assert_response :unprocessable_entity
    assert_equal [{ "field" => "$", "code" => "invalid_value" }], errors
  end

  test "a 415 names no field and creates nothing" do
    post "/api/claims", params: "claim_number=C-1", headers: auth.merge("Content-Type" => "text/plain")
    assert_response :unsupported_media_type
    assert_equal [{ "field" => nil, "code" => "unsupported_media_type" }], errors
    assert_equal 0, Claim.count
  end

  test "create answers 201 with a Location and the claim resource" do
    post "/api/claims", params: JSON.generate(claim_attrs("C.1")), headers: auth.merge("Content-Type" => "application/json")
    assert_response :created
    assert_equal "/api/claims/C.1", response.location
    get "/api/claims/C.1", headers: auth
    assert_response :ok
    assert_equal %w[claim dispatch], response.parsed_body.keys
  end

  test "stats on an empty database run one grouped query" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('"claims"') }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get "/api/claims/stats", headers: auth }
    assert_response :ok
    assert_equal 1, queries.size
    assert_match(/GROUP BY/, queries.first)
  end

  test "an unexpected error is a JSON 500 with an errors body" do
    ClaimStats.stub(:new, -> { raise "boom" }) { get "/api/claims/stats", headers: auth }
    assert_response :internal_server_error
    assert_equal "internal_error", errors.first["code"]
  end
end
