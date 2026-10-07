require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # Signs the session cookie that carries the web UI's CSRF token. There are no
  # credentials files, so it must come from the environment (docs/CONFIGURATION.md).
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "").strip.presence || raise(
    "refusing to boot in production: SECRET_KEY_BASE is not set. " \
    "Generate one with `bin/rails secret` (see docs/CONFIGURATION.md)."
  )
  config.action_controller.perform_caching = true

  # TLS is terminated in front of the app; set RAILS_FORCE_SSL=1 to enforce it here too.
  config.force_ssl = ENV["RAILS_FORCE_SSL"] == "1"

  config.logger = ActiveSupport::Logger.new($stdout)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }
  config.log_tags = [:request_id]
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [:id]
end
