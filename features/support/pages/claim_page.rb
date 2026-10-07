require_relative "base_page"

# A claim's fields, its dispatch explanation and history, and the "Re-dispatch" button,
# which asks for confirmation and renders its result asynchronously (Q51).
class ClaimPage < BasePage
  CONTAINER = "claim-detail".freeze

  def initialize(claim_number = nil)
    super()
    @claim_number = claim_number
  end

  def load
    visit "/claims/#{ERB::Util.url_encode(@claim_number)}"
    assert_showing(@claim_number)
  end

  # Identified by its container and the claim number it shows, never by the URL.
  def assert_showing(claim_number)
    assert_displayed
    assert_shows_exactly("claim-claim_number", claim_number)
    self
  end
end
