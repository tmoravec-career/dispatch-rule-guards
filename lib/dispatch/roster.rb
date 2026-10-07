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

    # Validates like the file loader (Q55 G5), so a roster built in code can't hold
    # an over-capacity adjuster, duplicate IDs or malformed fields either. Keeps a frozen
    # copy of the list, so neither the caller nor a reader of #adjusters can change it.
    # Phase 3 needn't build a Roster: Engine#decide accepts any object responding to #adjusters.
    def initialize(adjusters)
      self.class.validate_adjusters!(adjusters)
      @adjusters = adjusters.dup.freeze
      @by_id = adjusters.to_h { |a| [a.id, a] }
    end

    def self.validate_adjusters!(adjusters)
      collector = ErrorCollector.new
      unless adjusters.is_a?(Array) && adjusters.all? { |a| a.is_a?(Adjuster) }
        collector.add("invalid_value", "adjusters", "a roster needs an array of Adjusters")
        collector.raise_if_any!
      end
      validate_list(adjusters.map(&:to_h), collector)
      collector.raise_if_any!
    end

    def find(id)
      @by_id.fetch(id) { raise KeyError, "unknown adjuster #{id}" }
    end

    # Deep copy, so a replay can start from the same state twice (Q31).
    def copy
      Roster.new(adjusters.map { |a| Adjuster.from_h(a.to_h) })
    end

    # Sets the open-claims counter directly (seed data, test setup). Validated like any
    # other change: a count below 0 or above capacity raises and changes nothing.
    def set_open_claims(id, count)
      update(id, open_claims: count)
    end

    # Replaces an adjuster's attributes, e.g. update("ADJ-004", active: false). The result
    # is validated as a whole roster; on error nothing changes. On success every Adjuster
    # object is replaced, so references taken before the update are stale.
    def update(id, **changes)
      index = adjusters.index(find(id))
      hashes = adjusters.map(&:to_h)
      hashes[index] = hashes[index].merge(changes.transform_keys(&:to_s))
      collector = ErrorCollector.new
      self.class.validate_list(hashes, collector)
      collector.raise_if_any!

      @adjusters = hashes.map { |h| Adjuster.from_h(h) }.freeze
      @by_id = @adjusters.to_h { |a| [a.id, a] }
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
