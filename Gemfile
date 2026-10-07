source "https://rubygems.org"

# The engine (lib/dispatch) and bin/rule_diff need no gems: they run with plain
# `ruby -Ilib` and never load anything below.

# The Rails app: a thin layer over the engine. Only the frameworks it uses
# (no ActionCable, ActionMailbox, ActionMailer, ActiveStorage, ActiveJob).
gem "railties", "~> 7.2.4"
gem "activerecord", "~> 7.2.4"
gem "actionpack", "~> 7.2.4"
gem "actionview", "~> 7.2.4"
gem "sqlite3", ">= 2.1"
gem "puma", ">= 6.0"
gem "tzinfo-data", platforms: %i[windows jruby]

# Acceptance and unit suites. Required explicitly where they're used, so the app
# itself never loads them (and the audit subprocess never blocks network calls).
group :test do
  gem "cucumber", "~> 9.2", require: false
  gem "cucumber-rails", "~> 3.1", require: false
  gem "database_cleaner-active_record", "~> 2.2", require: false
  gem "json_schemer", "~> 2.5", require: false
  gem "minitest", "~> 5.20", require: false
  # Headless Chrome for the @javascript UI scenarios (re-dispatch confirmation, Q51).
  gem "selenium-webdriver", "~> 4.30", require: false
  gem "webmock", "~> 3.26", require: false
end
