# Presentation for the claim form: field errors are linked to their field with
# aria-invalid and aria-describedby (Q41). The wording is not part of the spec.
module ClaimsHelper
  FIELD_ERROR_MESSAGES = {
    "missing" => "This field is required.",
    "inclusion" => "Choose one of the listed options.",
    "invalid_value" => "Enter a valid value.",
    "not_an_integer" => "Enter whole dollars: cents must be .00.",
    "out_of_range" => "Enter an amount of $0 or more.",
    "duplicate_claim_number" => "A claim with this number already exists."
  }.freeze

  MONEY_INVALID_MESSAGE = "Enter whole dollars, e.g. 12000, $12,000 or 12,000.00.".freeze

  def field_error_id(field)
    "claim_#{field}_error"
  end

  # Attributes for the field's input: marked invalid and described by its error, if any.
  def field_aria(form, field)
    return {} unless form.error?(field)

    { "aria-invalid" => "true", "aria-describedby" => field_error_id(field) }
  end

  def field_error(form, field)
    return unless form.error?(field)

    code = form.errors.fetch(field)
    message = FIELD_ERROR_MESSAGES.fetch(code, FIELD_ERROR_MESSAGES["invalid_value"])
    message = MONEY_INVALID_MESSAGE if code == "invalid_value" && ClaimForm::MONEY_FIELDS.include?(field)
    tag.p(message, id: field_error_id(field), class: "field-error")
  end

  def money(dollars)
    dollars.nil? ? "" : number_to_currency(dollars, precision: 0)
  end
end
