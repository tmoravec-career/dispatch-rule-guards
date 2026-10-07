require_relative "pages/new_claim_page"
require_relative "pages/claim_page"
require_relative "pages/work_queue_page"
require_relative "pages/adjusters_page"
require_relative "pages/rules_page"

# Which page object the generic UI steps delegate to (STEP_GLOSSARY.md section 5).
module UiWorld
  PAGES = {
    "new claim" => NewClaimPage,
    "work queue" => WorkQueuePage,
    "adjusters" => AdjustersPage,
    "rules" => RulesPage
  }.freeze

  def page_class(name)
    PAGES.fetch(name) { raise ArgumentError, "no page named #{name.inspect} (known: #{PAGES.keys.join(', ')})" }
  end

  # The page the last step navigated to. Generic steps (fields, buttons, testids) work on
  # whichever page is showing, so before any visit it is a plain BasePage.
  def current_page
    @current_page ||= BasePage.new
  end

  def on_page(page)
    @current_page = page
  end
end

World(UiWorld)
