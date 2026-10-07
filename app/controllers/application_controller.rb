# Base for the web UI. The UI is unauthenticated in v1 (Q39). Controllers only wire
# requests to the models and services; routing decisions stay in the engine.
class ApplicationController < ActionController::Base
  private

  def render_not_found(message)
    @message = message
    render "shared/not_found", status: :not_found
  end
end
