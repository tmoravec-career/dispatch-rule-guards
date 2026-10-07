Rails.application.routes.draw do
  get "up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }

  # Claim numbers may contain dots, so they match any path segment.
  claim_number = { claim_number: %r{[^/]+} }

  namespace :api do
    # Declared before :claim_number, so "stats" is never taken for a claim number (Q43).
    get "claims/stats", to: "claims#stats"
    get "claims", to: "claims#index"
    post "claims", to: "claims#create"
    get "claims/:claim_number", to: "claims#show", constraints: claim_number
    post "claims/:claim_number/dispatch", to: "claims#redispatch", constraints: claim_number

    # Anything else under /api is still authenticated, rate limited and answered in JSON.
    match "*path", to: "base#route_not_found", via: :all, format: false
  end

  # The web UI (phase 3b), unauthenticated in v1 (Q39). The claim form lives outside
  # /claims/, so no claim number (e.g. "new") is ever shadowed by it.
  root "claims#index"
  get "claims", to: "claims#index", as: :claims
  post "claims", to: "claims#create"
  get "new-claim", to: "claims#new", as: :new_claim
  get "claims/:claim_number", to: "claims#show", as: :claim, constraints: claim_number, format: false
  post "claims/:claim_number/dispatch", to: "claims#redispatch", as: :redispatch_claim, constraints: claim_number,
                                        format: false
  get "adjusters", to: "adjusters#index", as: :adjusters
  get "rules", to: "rules#index", as: :rules
end
