module Dispatch
  # An in-memory roster: the engine's capacity bookkeeping for single-threaded use
  # (unit tests, the impact gate's replay). The web app keeps the authoritative
  # counter in the DB and claims a slot with an atomic conditional UPDATE (Q37).
  class Roster
    attr_reader :adjusters

    def self.load_file(path)
      from_h(Dispatch.read_json_file(path), source: path)
    end

    # Expects {"adjusters": [...]}, validated as strictly as a rules config.
    def self.from_h(data, source: nil)
      collector = ErrorCollector.new
      if data.is_a?(Hash)
        collector.check_keys(data, "", allowed: %w[adjusters], required: %w[adjusters])
        list = data["adjusters"]
        if data.key?("adjusters") && !list.is_a?(Array)
          collector.add("invalid_value", "adjusters", "\"adjusters\" must be an array")
        elsif list.is_a?(Array)
          validate_list(list, collector)
        end
      else
        collector.add("invalid_value", "$", "a roster must be a JSON object with an \"adjusters\" array")
      end
      collector.raise_if_any!(source)
      new(data["adjusters"].map { |a| Adjuster.from_h(a) })
    end

    def self.validate_list(list, collector)
      seen = {}
      list.each_with_index do |item, i|
        Adjuster.validate(item, "adjusters[#{i}]", collector)
        id = item.is_a?(Hash) ? item["id"] : nil
        next unless id.is_a?(String)

        if seen.key?(id)
          collector.add("duplicate_adjuster_id", "adjusters[#{i}].id", "adjuster id #{id} is already used by adjusters[#{seen[id]}]")
        else
          seen[id] = i
        end
      end
    end

    def initialize(adjusters)
      @adjusters = adjusters
      @by_id = adjusters.to_h { |a| [a.id, a] }
    end

    def find(id)
      @by_id.fetch(id) { raise KeyError, "unknown adjuster #{id}" }
    end

    # Deep copy, so a replay can start from the same state twice (Q31).
    def copy
      Roster.new(adjusters.map { |a| Adjuster.from_h(a.to_h) })
    end

    # Sets the open-claims counter directly (seed data, test setup).
    def set_open_claims(id, count)
      raise ArgumentError, "open claims must be an integer >= 0" unless Dispatch.non_negative_integer?(count)

      find(id).assign_open_claims!(count)
    end

    # Replaces an adjuster's attributes, e.g. update("ADJ-004", active: false).
    def update(id, **changes)
      current = find(id)
      replacement = Adjuster.from_h(current.to_h.merge(changes.transform_keys(&:to_s)))
      @adjusters = adjusters.map { |a| a.id == id ? replacement : a }
      @by_id[id] = replacement
    end

    # Takes one slot. Refuses to over-assign, so capacity can never be exceeded here.
    def assign!(id)
      adjuster = find(id)
      raise CapacityError, "#{id} is at capacity (#{adjuster.open_claims}/#{adjuster.capacity})" if adjuster.full?

      adjuster.increment_open_claims!
    end

    def to_h
      { "adjusters" => adjusters.map(&:to_h) }
    end
  end
end
