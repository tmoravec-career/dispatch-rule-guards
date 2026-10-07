require "selenium-webdriver"

# Browser drivers for the @ui scenarios (STEP_GLOSSARY.md section 5).
#
# - Scenarios without @javascript use rack_test: no browser, no server, in-process.
# - @javascript scenarios (the re-dispatch confirm dialog, Q51) use headless Chrome through
#   Selenium. cucumber-rails switches to Capybara.javascript_driver for that tag, and
#   features/support/database.rb gives the tag deletion cleaning, because the app then runs
#   in a Puma thread on its own database connection.
#
# Selenium Manager (bundled with selenium-webdriver) finds or fetches the chromedriver that
# matches the installed Chrome, so nothing else needs installing. Where Chrome isn't in a
# standard place (Debian's Chromium in the Docker test image, setup-chrome in CI), set
# CHROME_BIN and CHROMEDRIVER_PATH to use those binaries instead.
Capybara.register_driver(:headless_chrome) do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--window-size=1280,1000")
  options.add_argument("--disable-gpu")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--disable-search-engine-choice-screen")
  options.add_argument("--no-first-run")
  # Chrome refuses to start sandboxed as root (typical in Docker), and most CI runners have
  # no user namespaces for its sandbox. Ruby on Windows reports uid 0 for everyone, so
  # root is only checked elsewhere.
  running_as_root = !Gem.win_platform? && Process.uid.zero?
  options.add_argument("--no-sandbox") if ENV["CI"] || running_as_root
  options.binary = ENV["CHROME_BIN"] unless ENV["CHROME_BIN"].to_s.empty?
  driver_options = { browser: :chrome, options: options }
  unless ENV["CHROMEDRIVER_PATH"].to_s.empty?
    driver_options[:service] = Selenium::WebDriver::Service.chrome(path: ENV["CHROMEDRIVER_PATH"])
  end
  Capybara::Selenium::Driver.new(app, **driver_options)
end

Capybara.javascript_driver = :headless_chrome
Capybara.server = :puma, { Silent: true }
# The upper bound for every waiting finder and matcher; they return as soon as they match.
Capybara.default_max_wait_time = 5
