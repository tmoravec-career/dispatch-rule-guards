module Api
  # Every API request: Bearer auth first (401), then the per-token rate limit (429), then
  # the action (Q39, Q48). Every response, success or error, is JSON, and every error
  # body is {"errors": [{"field", "code"}]} (Q20, Q44).
  #
  # The JSON body is parsed by the actions themselves (never through `params`), so a
  # malformed body is a 400 malformed_json from the action, not a framework error page.
  class BaseController < ActionController::API
    ApiError = Struct.new(:field, :code)
    BEARER = /\ABearer (\S+)\z/

    wrap_parameters false

    before_action :authenticate!
    before_action :enforce_rate_limit!

    rescue_from StandardError, with: :internal_error

    # Any unrouted /api path or method.
    def route_not_found
      render_error(:not_found, "not_found")
    end

    private

    attr_reader :api_role

    # The scheme is "Bearer" and the token is matched exactly, case-sensitively (Q39).
    def authenticate!
      header = request.authorization
      token = header&.match(BEARER)&.captures&.first
      @api_token, @api_role = token && DispatchSettings.api_tokens.find do |known, _role|
        ActiveSupport::SecurityUtils.secure_compare(known, token)
      end
      return if @api_role

      response.headers["WWW-Authenticate"] =
        header.blank? ? %(Bearer realm="dispatch") : %(Bearer realm="dispatch", error="invalid_token")
      render_error(:unauthorized, "unauthorized")
    end

    # Counts every authenticated request, including ones that end in 4xx (Q48).
    def enforce_rate_limit!
      decision = DispatchSettings.rate_limiter.check(@api_token)
      return if decision.allowed?

      response.headers["Retry-After"] = decision.retry_after.to_s
      render_error(:too_many_requests, "rate_limited")
    end

    # Adjuster tokens are read-only (Q39).
    def require_ops!
      render_error(:forbidden, "forbidden") unless api_role == "ops"
    end

    def render_error(status, code, field: nil)
      render_errors(status, [ApiError.new(field, code)])
    end

    def render_errors(status, errors)
      render json: { "errors" => errors.map { |e| { "field" => e.field, "code" => e.code } } }, status: status
    end

    def internal_error(exception)
      Rails.logger.error("#{exception.class}: #{exception.message}\n#{exception.backtrace&.first(15)&.join("\n")}")
      render_error(:internal_server_error, "internal_error")
    end
  end
end
