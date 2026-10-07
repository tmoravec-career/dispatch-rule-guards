# The work queue, the claim form, the claim page and re-dispatch (Q35, Q41, Q50, Q51).
# Input is checked by ClaimForm and ClaimListQuery; every dispatch goes through ClaimDispatcher.
class ClaimsController < ApplicationController
  before_action :find_claim, only: %i[show redispatch]

  # GET /claims: filters live in the query string, so they survive a reload (Q35).
  def index
    @filters = request.query_parameters.slice(*ClaimListQuery::FILTERS).compact_blank
    query = ClaimListQuery.new(@filters)
    @invalid_filters = query.errors.map(&:field)
    @claims = query.valid? ? query.scope.to_a : []
    @queues = Claim.known_queues(DispatchSettings.rules)
    @adjuster_ids = Adjuster.order(:id).pluck(:id)
    render :index, status: query.valid? ? :ok : :unprocessable_entity
  end

  # GET /new-claim
  def new
    @form = ClaimForm.new
  end

  # POST /claims: dispatch and show the result, or re-render the form with field errors.
  def create
    @form = ClaimForm.new(claim_params)
    if @form.submit
      redirect_to claim_path(claim_number: @form.claim.claim_number), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /claims/:claim_number
  def show; end

  # POST /claims/:claim_number/dispatch (Q19). The page's script asks for confirmation and
  # sends this in the background, then swaps in the returned dispatch panel (Q51).
  def redispatch
    @claim = ClaimDispatcher.new.redispatch(@claim)
    if request.xhr?
      render partial: "claims/dispatch_panel", locals: { claim: @claim }
    else
      redirect_to claim_path(claim_number: @claim.claim_number), status: :see_other
    end
  end

  private

  def find_claim
    @claim = Claim.find_by(claim_number: params[:claim_number])
    render_not_found("No claim #{params[:claim_number]}.") unless @claim
  end

  def claim_params
    submitted = params[:claim]
    submitted.is_a?(ActionController::Parameters) ? submitted.permit(*ClaimForm::FIELDS).to_h : {}
  end
end
