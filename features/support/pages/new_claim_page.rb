require_relative "base_page"

# "File a claim": fields "Claim number", "Line of business", "Estimated loss",
# "Vehicle value", "CAT event", "Loss state"; button "File claim".
class NewClaimPage < BasePage
  PATH = "/new-claim".freeze
  CONTAINER = "claim-form".freeze
  SUBMIT = "File claim".freeze

  # Fills each [label, value] pair by the field's type, then submits. Omitted fields stay blank.
  def file_claim(fields)
    load
    fields.each { |label, value| set_field(label, value) }
    press(SUBMIT)
  end
end
