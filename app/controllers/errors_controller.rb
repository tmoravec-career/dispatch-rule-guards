# config.exceptions_app: errors raised outside a controller's own handling (no route, an
# unhandled exception, a failed CSRF check) get an error response here.
#
# - Under /api the body is the API's JSON errors body, so no API path ever returns HTML.
# - Anywhere else the request came from a browser, so it gets a minimal HTML page instead of
#   raw JSON (BUG-019): e.g. an expired form token (422) or a server error (500).
#
# This is an ActionController::API on purpose: it has no CSRF check of its own, so it can
# answer the POST whose token just failed.
class ErrorsController < ActionController::API
  PAGE_MESSAGES = {
    404 => "There is nothing at this address.",
    422 => "The request could not be completed. If you were submitting a form, the page may have " \
           "expired: go back, reload the page and try again."
  }.freeze
  DEFAULT_MESSAGE = "Something went wrong on our side. Try again in a moment.".freeze

  def show
    status = request.path_info.delete_prefix("/").to_i
    status = 500 unless Rack::Utils::HTTP_STATUS_CODES.key?(status) && status >= 400
    title = Rack::Utils::HTTP_STATUS_CODES.fetch(status)
    if api_request?
      render json: { "errors" => [{ "field" => nil, "code" => error_code(title) }] }, status: status
    else
      render html: error_page(status, title), status: status, content_type: "text/html"
    end
  end

  private

  # "Internal Server Error" -> "internal_server_error". Rack's status texts are binary
  # strings, which String#parameterize refuses to transliterate, so this is done by hand.
  def error_code(title)
    title.downcase.gsub(/[^a-z0-9]+/, "_").delete_suffix("_")
  end

  def api_request?
    path = request.env["action_dispatch.original_path"] || request.path
    path == "/api" || path.start_with?("/api/")
  end

  def error_page(status, title)
    message = PAGE_MESSAGES.fetch(status, status >= 500 ? DEFAULT_MESSAGE : "The request could not be completed.")
    h = ERB::Util.method(:html_escape)
    <<~HTML.html_safe
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h.call(title)} | Dispatch Rules Guard</title>
        <link rel="icon" href="data:,">
        <style>body { font-family: system-ui, sans-serif; margin: 2rem 1.5rem; color: #1f2328; }</style>
      </head>
      <body>
        <main>
          <h1>#{status} #{h.call(title)}</h1>
          <p>#{h.call(message)}</p>
          <p><a href="/claims">Back to the work queue</a></p>
        </main>
      </body>
      </html>
    HTML
  end
end
