# The "File a claim" form. Turns the submitted text into a claim body (money through
# Dispatch::MoneyInput, Q50), validates it with the API's own rules (Dispatch::ClaimInput)
# and dispatches it through ClaimDispatcher. Errors are kept per field as ClaimInput codes,
# so the form can mark each field invalid (Q41).
class ClaimForm
  FIELDS = Dispatch::Claim::FIELDS
  MONEY_FIELDS = Dispatch::NUMERIC_FIELDS

  # `values` are the submitted strings, echoed back when the form is re-rendered.
  attr_reader :values, :errors, :claim

  def initialize(params = {})
    @values = FIELDS.index_with { |field| params[field].to_s }
    @errors = {}
  end

  # Dispatches the claim and returns true, or records field errors and returns false.
  def submit
    body = {}
    FIELDS.each do |field|
      if MONEY_FIELDS.include?(field)
        body[field], code = Dispatch::MoneyInput.parse(values[field])
        errors[field] = code if code
      else
        body[field] = parse_text(field)
      end
    end
    attributes, input_errors = Dispatch::ClaimInput.validate(body)
    # A field that failed to parse already has its own error (not "missing").
    input_errors.each { |e| errors[e.field] ||= e.code }
    return false unless errors.empty?

    @claim = ClaimDispatcher.new.create(attributes)
    true
  rescue ClaimDispatcher::DuplicateClaimNumber
    errors["claim_number"] = "duplicate_claim_number"
    false
  end

  def error?(field)
    errors.key?(field)
  end

  def cat_event?
    values["cat_event"] == "1"
  end

  # out_of_range covers both ends of a money field (Q58): :minimum for a negative amount,
  # :maximum for one above Dispatch::ClaimInput::MAX_MONEY. Nil for any other error.
  def out_of_range_bound(field)
    return unless errors[field] == "out_of_range"

    values[field].include?("-") ? :minimum : :maximum
  end

  private

  # A blank text field or select is absent. The checkbox posts "1" when checked.
  def parse_text(field)
    return cat_event? if field == "cat_event"

    values[field].strip.presence
  end
end
