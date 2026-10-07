module Api
  # Claims over REST (Q20, Q38, Q43). Claims are addressed by claim_number (Q22).
  class ClaimsController < BaseController
    before_action :require_ops!, only: %i[create redispatch]
    before_action :find_claim, only: %i[show redispatch]

    # GET /api/claims
    def index
      query = ClaimListQuery.new(request.query_parameters)
      return render_errors(:unprocessable_entity, query.errors) unless query.valid?

      render json: query.result
    end

    # GET /api/claims/stats
    def stats
      render json: ClaimStats.new.to_h
    end

    # GET /api/claims/:claim_number
    def show
      render json: @claim.as_resource
    end

    # POST /api/claims: create and dispatch. 201 even when unassigned (Q20).
    def create
      return render_error(:unsupported_media_type, "unsupported_media_type") unless request.media_type == "application/json"

      body = parse_json_body
      return render_error(:bad_request, "malformed_json") if body == :malformed

      attributes, errors = Dispatch::ClaimInput.validate(body)
      return render_errors(:unprocessable_entity, errors) unless errors.empty?

      claim = ClaimDispatcher.new.create(attributes)
      render json: claim.as_resource, status: :created, location: "/api/claims/#{ERB::Util.url_encode(claim.claim_number)}"
    rescue ClaimDispatcher::DuplicateClaimNumber
      render_error(:conflict, "duplicate_claim_number", field: "claim_number")
    end

    # POST /api/claims/:claim_number/dispatch: re-dispatch with the current rules (Q19).
    def redispatch
      render json: ClaimDispatcher.new.redispatch(@claim).as_resource
    end

    private

    def find_claim
      @claim = Claim.find_by(claim_number: request.path_parameters[:claim_number])
      render_error(:not_found, "not_found", field: "claim_number") unless @claim
    end

    def parse_json_body
      Dispatch.parse_json(request.raw_post.to_s)
    rescue Dispatch::ConfigError
      :malformed
    end
  end
end
