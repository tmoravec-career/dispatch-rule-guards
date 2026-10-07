require "rack/test"

# Sends API requests straight into the Rails app through Rack::Test, with the
# Authorization header the auth steps chose (STEP_GLOSSARY.md section 6).
module ApiClient
  def api_session
    @api_session ||= Rack::Test::Session.new(Rails.application)
  end

  # nil sends no Authorization header.
  attr_accessor :api_authorization

  def use_api_token(token)
    self.api_authorization = "Bearer #{token}"
  end

  # Sends one request and remembers its response and the SQL it ran.
  def api_request(method, path, body: nil, content_type: nil)
    env = { method: method.to_s.upcase }
    env["HTTP_AUTHORIZATION"] = api_authorization if api_authorization
    env["CONTENT_TYPE"] = content_type if content_type
    env[:input] = body if body
    queries = []
    collect = ->(*, payload) { queries << payload }
    ActiveSupport::Notifications.subscribed(collect, "sql.active_record") do
      api_session.request(path, env)
    end
    @last_request_queries = queries
    @api_response = api_session.last_response
  end

  def api_response
    @api_response or flunk("no API request has been made")
  end

  def last_request_queries
    @last_request_queries or flunk("no API request has been made")
  end

  def response_json
    JSON.parse(api_response.body)
  rescue JSON::ParserError => e
    flunk("the response body is not JSON (#{e.message}): #{api_response.body[0, 300]}")
  end

  def post_json(path, document)
    api_request(:post, path, body: JSON.generate(document), content_type: "application/json")
  end

  # The "a valid claim" body from the api_dispatch.feature header comment.
  def valid_claim(claim_number)
    { "claim_number" => claim_number, "line_of_business" => "auto", "estimated_loss" => 12_000,
      "vehicle_value" => 30_000, "cat_event" => false, "loss_state" => "TX" }
  end
end

World(ApiClient)
