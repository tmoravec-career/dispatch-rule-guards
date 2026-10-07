require_relative "../app_helper"

# BUG-024: forgery protection is off in the test environment, so these tests switch it on
# and prove the web UI's two POSTs carry a working CSRF token and fail without one. The
# form posts the hidden authenticity_token; the re-dispatch script sends the page's
# csrf-token meta tag as X-CSRF-Token.
class CsrfTest < ActionDispatch::IntegrationTest
  include AppTestHelpers

  def setup
    super
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  def teardown
    ActionController::Base.allow_forgery_protection = @forgery_protection
    super
  end

  def claim_fields(number)
    { claim_number: number, line_of_business: "auto", estimated_loss: "$12,000", loss_state: "TX" }
  end

  def form_token
    css_select('[data-testid="claim-form"] form input[name="authenticity_token"]').sole["value"]
  end

  def meta_token
    css_select('meta[name="csrf-token"]').sole["content"]
  end

  test "filing a claim works with the form's token" do
    get "/new-claim"
    post "/claims", params: { authenticity_token: form_token, claim: claim_fields("CLM-X1") }
    assert_redirected_to "/claims/CLM-X1"
    assert Claim.exists?(claim_number: "CLM-X1")
  end

  test "filing a claim without a token, or with a wrong one, is rejected and dispatches nothing" do
    get "/new-claim"
    [nil, "forged"].each do |token|
      params = { claim: claim_fields("CLM-X2") }
      params[:authenticity_token] = token if token
      post "/claims", params: params
      assert_response :unprocessable_entity, "token #{token.inspect}"
    end
    refute Claim.exists?(claim_number: "CLM-X2")
  end

  test "re-dispatch in the background works with the page's meta token" do
    ClaimDispatcher.new.create(claim_attrs("CLM-X3"))
    get "/claims/CLM-X3"
    post "/claims/CLM-X3/dispatch", xhr: true, headers: { "X-CSRF-Token" => meta_token }
    assert_response :ok
    assert_equal 2, Claim.find_by!(claim_number: "CLM-X3").dispatch_count
  end

  test "re-dispatch without a token is rejected and changes nothing" do
    ClaimDispatcher.new.create(claim_attrs("CLM-X4"))
    get "/claims/CLM-X4"
    post "/claims/CLM-X4/dispatch", xhr: true
    assert_response :unprocessable_entity
    post "/claims/CLM-X4/dispatch", xhr: true, headers: { "X-CSRF-Token" => "forged" }
    assert_response :unprocessable_entity
    assert_equal 1, Claim.find_by!(claim_number: "CLM-X4").dispatch_count
  end
end
