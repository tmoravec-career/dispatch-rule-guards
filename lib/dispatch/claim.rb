module Dispatch
  # A claim as the engine sees it (Q1). A nil vehicle_value means the field is
  # absent, so conditions on it don't match (Q3). cat_event defaults to false.
  class Claim
    FIELDS = %w[claim_number line_of_business estimated_loss vehicle_value cat_event loss_state].freeze
    REQUIRED = %w[claim_number line_of_business estimated_loss loss_state].freeze
    MAX_CLAIM_NUMBER_LENGTH = 32

    attr_reader :claim_number, :line_of_business, :estimated_loss, :vehicle_value, :cat_event, :loss_state

    def initialize(claim_number:, line_of_business:, estimated_loss:, loss_state:, vehicle_value: nil, cat_event: false)
      @claim_number = claim_number
      @line_of_business = line_of_business
      @estimated_loss = estimated_loss
      @vehicle_value = vehicle_value
      @cat_event = cat_event.nil? ? false : cat_event
      @loss_state = loss_state
      freeze
    end

    # Unvalidated construction from a string- or symbol-keyed hash. Absent keys become
    # absent fields (nil), which conditions treat as not matching (Q3).
    def self.from_h(hash)
      attrs = hash.to_h.transform_keys(&:to_s)
      new(**FIELDS.to_h { |f| [f.to_sym, attrs[f]] })
    end

    # Validates a parsed claims file (a JSON array of claim objects) and returns Claims.
    # Every problem is reported together, as for rules configs.
    def self.load_all(data, source: nil)
      collector = ErrorCollector.new
      unless data.is_a?(Array)
        collector.add("invalid_value", "$", "a claims file must be a JSON array of claims")
        collector.raise_if_any!(source)
      end
      seen = {}
      data.each_with_index do |item, i|
        validate(item, "[#{i}]", collector)
        number = item.is_a?(Hash) ? item["claim_number"] : nil
        next unless number.is_a?(String)

        if seen.key?(number)
          collector.add("duplicate_claim_number", "[#{i}].claim_number", "claim number #{number} repeats [#{seen[number]}]")
        else
          seen[number] = i
        end
      end
      collector.raise_if_any!(source)
      data.map { |item| from_h(item) }
    end

    def self.load_file(path)
      load_all(Dispatch.read_json_file(path), source: path)
    end

    def self.validate(item, path, collector)
      unless item.is_a?(Hash)
        collector.add("invalid_value", path, "a claim must be a JSON object")
        return
      end
      collector.check_keys(item, path, allowed: FIELDS, required: REQUIRED)
      check = lambda do |key, ok, message|
        collector.add("invalid_value", "#{path}.#{key}", message) if item.key?(key) && !ok.call(item[key])
      end
      check.call("claim_number", ->(v) { Dispatch.non_empty_string?(v) && v.length <= MAX_CLAIM_NUMBER_LENGTH },
                 "must be a non-empty string of at most #{MAX_CLAIM_NUMBER_LENGTH} characters")
      check.call("line_of_business", ->(v) { LINES_OF_BUSINESS.include?(v) }, "must be one of #{LINES_OF_BUSINESS.join(', ')}")
      check.call("estimated_loss", ->(v) { Dispatch.non_negative_integer?(v) }, "must be a whole-dollar integer >= 0")
      check.call("vehicle_value", ->(v) { v.nil? || Dispatch.non_negative_integer?(v) }, "must be null or a whole-dollar integer >= 0")
      check.call("cat_event", ->(v) { v == true || v == false }, "must be true or false")
      check.call("loss_state", ->(v) { US_STATES.include?(v) }, "must be an uppercase USPS state code")
    end

    # Value of a routing field, or nil when the claim doesn't have it.
    def [](field)
      case field.to_s
      when "claim_number" then claim_number
      when "line_of_business" then line_of_business
      when "estimated_loss" then estimated_loss
      when "vehicle_value" then vehicle_value
      when "cat_event" then cat_event
      when "loss_state" then loss_state
      end
    end

    def to_h
      FIELDS.to_h { |f| [f, self[f]] }
    end

    def ==(other)
      other.is_a?(Claim) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end
end
