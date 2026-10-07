require_relative "base_page"

# The work queue: selects "Queue", "Status", "Adjuster", "Loss state"; buttons
# "Apply filters" and "Clear filters"; rows claim-row-<claim_number>. Filters are kept in
# the URL, so reload keeps them (Q35).
class WorkQueuePage < BasePage
  PATH = "/claims".freeze
  CONTAINER = "work-queue".freeze
end
