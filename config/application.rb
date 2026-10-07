require_relative "boot"

require "rails"
# Only the frameworks the app uses: no ActionCable, ActionMailbox, ActionMailer,
# ActionText, ActiveJob or ActiveStorage.
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

# The plain-Ruby engine. It is required, not autoloaded: lib/dispatch must stay
# loadable with `ruby -Ilib` and no Rails, so Zeitwerk never manages it.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "dispatch"

module DispatchRulesGuard
  class Application < Rails::Application
    config.load_defaults 7.2

    # lib/ holds the engine (required above) and rake tasks; nothing there is autoloaded.
    config.generators.system_tests = nil
    config.time_zone = "UTC"

    # Errors raised outside a controller's own handling: JSON under /api, so every API
    # response is JSON; a minimal HTML page for the browser UI (ErrorsController).
    config.exceptions_app = ->(env) { ErrorsController.action(:show).call(env) }
  end
end
