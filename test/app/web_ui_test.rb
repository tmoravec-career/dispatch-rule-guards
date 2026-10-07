require_relative "../app_helper"

# Request-level checks on the web UI that the features don't spell out.
class WebUiTest < ActionDispatch::IntegrationTest
  include AppTestHelpers

  def file(number, **attrs)
    ClaimDispatcher.new.create(claim_attrs(number, **attrs))
  end

  test "every page renders without authentication (Q39)" do
    file("CLM-W1")
    ["/", "/claims", "/new-claim", "/claims/CLM-W1", "/adjusters", "/rules"].each do |path|
      get path
      assert_response :ok, path
      assert_equal "text/html", response.media_type, path
    end
  end

  test "an unknown claim is an HTML 404" do
    get "/claims/CLM-NOPE"
    assert_response :not_found
    assert_equal "text/html", response.media_type
  end

  test "a claim number with a dot or named like a page is still its own claim page" do
    file("CLM.7")
    file("new")
    get "/claims/CLM.7"
    assert_response :ok
    assert_includes response.body, "CLM.7"
    get "/claims/new"
    assert_response :ok
    assert_includes response.body, 'data-testid="claim-detail"'
  end

  test "a filter value outside the offered options is 422 with no rows" do
    file("CLM-W2")
    get "/claims", params: { queue: "no_such_queue", status: "" }
    assert_response :unprocessable_entity
    assert_includes response.body, 'data-testid="queue-empty"'
  end

  test "a queue removed from the rules is still offered while it holds claims (Q35)" do
    file("CLM-W3", vehicle: 120_000, state: "CA")
    queue = Claim.find_by!(claim_number: "CLM-W3").queue
    DispatchSettings.rules = Dispatch::RulesConfig.from_h({ "rules" => [] })
    get "/claims"
    assert_includes response.body, %(<option value="#{queue}">#{queue}</option>)
    get "/claims", params: { queue: queue }
    assert_response :ok
    assert_includes response.body, 'data-testid="claim-row-CLM-W3"'
  end

  test "re-dispatch without JavaScript redirects back to the claim; in the background it returns the panel" do
    file("CLM-W4")
    post "/claims/CLM-W4/dispatch"
    assert_redirected_to "/claims/CLM-W4"
    post "/claims/CLM-W4/dispatch", xhr: true
    assert_response :ok
    assert_equal 3, response.body.scan('data-testid="dispatch-history-entry"').size
    refute_includes response.body, "<html"
  end

  test "an invalid form re-renders with 422 and nothing is dispatched" do
    post "/claims", params: { claim: { claim_number: "CLM-W5", line_of_business: "auto", estimated_loss: "12,000.50",
                                       loss_state: "TX" } }
    assert_response :unprocessable_entity
    assert_includes response.body, 'aria-invalid="true"'
    refute Claim.exists?(claim_number: "CLM-W5")
  end
end
