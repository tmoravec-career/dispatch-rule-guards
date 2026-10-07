Rails.application.routes.draw do
  get "up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }
end
