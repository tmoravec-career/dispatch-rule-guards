module Dispatch
  # Parses a money amount typed into the web form (Q50) into whole dollars. A leading "$",
  # thousands commas and zero cents (".00") are accepted; non-zero cents, letters, signs,
  # exponents and misplaced commas are not. The API takes JSON integers only (ClaimInput).
  module MoneyInput
    # Digits either plain or grouped in threes, then optional cents.
    FORMAT = /\A(?<negative>-)?\$?(?<dollars>\d+|\d{1,3}(?:,\d{3})+)(?:\.(?<cents>\d{1,2}))?\z/

    module_function

    # Returns [dollars, nil], [nil, nil] for a blank field, or [nil, code] with a
    # ClaimInput code: invalid_value, not_an_integer or out_of_range.
    def parse(text)
      text = text.to_s.strip
      return [nil, nil] if text.empty?

      match = FORMAT.match(text.sub(/\A\$-/, "-$")) or return [nil, "invalid_value"]
      return [nil, "out_of_range"] if match[:negative]
      return [nil, "not_an_integer"] if match[:cents].to_i.positive?

      dollars = Integer(match[:dollars].delete(","), 10)
      dollars > ClaimInput::MAX_MONEY ? [nil, "out_of_range"] : [dollars, nil]
    end
  end
end
