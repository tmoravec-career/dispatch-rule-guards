# config.exceptions_app: errors raised outside a controller (e.g. no route) are answered
# with a JSON errors body too, so no path returns an HTML error page to an API client.
class ErrorsController < ActionController::API
  def show
    status = request.path_info.delete_prefix("/").to_i
    status = 500 unless Rack::Utils::HTTP_STATUS_CODES.key?(status) && status >= 400
    code = Rack::Utils::HTTP_STATUS_CODES.fetch(status).parameterize(separator: "_")
    render json: { "errors" => [{ "field" => nil, "code" => code }] }, status: status
  end
end
