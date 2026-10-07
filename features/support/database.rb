require "database_cleaner/active_record"

# Database cleaning (STEP_GLOSSARY.md section 9). cucumber-rails' own cleaning is off: its
# shared-connection strategy would hand one connection to every thread.
#
# - Scenarios whose data is read by another process or thread (the audit subprocess,
#   concurrent dispatch threads, k6, a browser-driven server) use DELETION, so every write
#   is really committed.
# - Other app scenarios (@api, @ui without @javascript) run inside a transaction that is
#   rolled back afterwards.
# - @engine and @cli scenarios never touch the database.
Cucumber::Rails::Database.autorun_database_cleaner = false

SHARED_DATABASE_TAGS = "@audit or @concurrency or @k6_pr or @k6_nightly or @javascript".freeze
APP_TAGS = "@api or @ui or @load".freeze

# Whatever an interrupted run left behind.
DatabaseCleaner[:active_record].clean_with(:deletion)

Before("(#{APP_TAGS}) and (#{SHARED_DATABASE_TAGS})") do
  DatabaseCleaner[:active_record].strategy = :deletion
  DatabaseCleaner.start
end

Before("(#{APP_TAGS}) and not (#{SHARED_DATABASE_TAGS})") do
  DatabaseCleaner[:active_record].strategy = :transaction
  DatabaseCleaner.start
end

After(APP_TAGS) do
  DatabaseCleaner.clean
end
