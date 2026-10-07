require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  # Eager load so a broken constant fails the suite, not a single scenario.
  config.eager_load = true

  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Error responses are rendered by the controllers themselves (JSON for the API).
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false

  config.active_support.deprecation = :stderr
  config.active_support.disallowed_deprecation = :raise
  config.active_support.disallowed_deprecation_warnings = []
  config.action_controller.raise_on_missing_callback_actions = true
end
