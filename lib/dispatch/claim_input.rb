module Dispatch
  # Validates a claim submitted over the API (Q1, Q2, Q20, Q50) and normalizes it into
  # attributes for Claim.from_h. Unlike Claim.validate (files, one code), every problem
  # gets the API's field-level code, and all of them are reported together.
  module ClaimInput
    Error = Struct.new(:field, :code)

    # Whole dollars above this can't round-trip through JSON numbers or the database.
    MAX_MONEY = 2**53 - 1

    module_function

    # Returns [attributes, errors]. Attributes are nil when there are errors.
    def validate(body)
      return [nil, [Error.new("$", "invalid_value")]] unless body.is_a?(Hash)

      errors = []
      check = ->(field, code) { errors << Error.new(field, code) if code }
      check.call("claim_number", claim_number_code(body["claim_number"]))
      check.call("line_of_business", enum_code(body["line_of_business"], LINES_OF_BUSINESS))
      check.call("estimated_loss", money_code(body["estimated_loss"], required: true))
      check.call("vehicle_value", money_code(body["vehicle_value"], required: false))
      check.call("cat_event", boolean_code(body["cat_event"]))
      check.call("loss_state", enum_code(body["loss_state"], US_STATES))
      (body.keys - Claim::FIELDS).each { |key| check.call(key.to_s, "unknown_field") }
      return [nil, errors] unless errors.empty?

      [normalize(body), errors]
    end

    # A claim number addresses the claim in URLs (Q22), so it can't contain "/" or control characters.
    def claim_number_code(value)
      return "missing" if value.nil?
      return "invalid_value" unless Dispatch.non_empty_string?(value)
      return "invalid_value" if value.length > Claim::MAX_CLAIM_NUMBER_LENGTH || value.match?(%r{[/[:cntrl:]]})

      nil
    end

    def enum_code(value, allowed)
      return "missing" if value.nil?

      allowed.include?(value) ? nil : "inclusion"
    end

    # Q50: JSON integers only. Strings (even "12000"), booleans, arrays and objects are
    # invalid_value; a fractional number is not_an_integer; a negative is out_of_range.
    def money_code(value, required:)
      return required ? "missing" : nil if value.nil?
      return "invalid_value" unless Dispatch.finite_number?(value)
      return "not_an_integer" unless value == value.floor
      return "out_of_range" if value.negative? || value > MAX_MONEY

      nil
    end

    def boolean_code(value)
      value.nil? || value == true || value == false ? nil : "not_a_boolean"
    end

    def normalize(body)
      money = ->(v) { v&.to_i }
      {
        "claim_number" => body["claim_number"],
        "line_of_business" => body["line_of_business"],
        "estimated_loss" => money.call(body["estimated_loss"]),
        "vehicle_value" => money.call(body["vehicle_value"]),
        "cat_event" => body["cat_event"] == true,
        "loss_state" => body["loss_state"]
      }
    end
  end
end
