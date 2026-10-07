require_relative "base_page"

# Every adjuster's licensing, skills, load and status (adjuster-row-<id>), with the badge
# adjuster-at-capacity-<id>.
class AdjustersPage < BasePage
  PATH = "/adjusters".freeze
  CONTAINER = "adjusters-page".freeze
end
