# Builders for the shared table formats in STEP_GLOSSARY.md: rules, roster and claims tables.
module Tables
  CLAIM_INTEGER_FIELDS = %w[estimated_loss vehicle_value].freeze

  module_function

  # Rules table -> {"rules" => [...]}. A header-only table is an empty rule set.
  def rules_hash(table)
    { "rules" => table.hashes.map { |row| rule_from_row(row) } }
  end

  def rule_from_row(row)
    {
      "id" => row.fetch("id"),
      "priority" => Integer(row.fetch("priority"), 10),
      "conditions" => conditions(row.fetch("conditions")),
      "queue" => row.fetch("queue"),
      "required_skills" => list(row.fetch("required_skills"))
    }
  end

  # "cat_event eq true; estimated_loss gte 50000" -> condition hashes, ANDed.
  def conditions(cell)
    cell.to_s.split(";").map(&:strip).reject(&:empty?).map { |clause| condition(clause) }
  end

  # "<field> <op> <value>"; `in` takes a comma-separated list.
  def condition(clause)
    field, op, raw = clause.strip.split(/\s+/, 3)
    raise ArgumentError, "malformed condition #{clause.inspect}" if raw.nil?

    value = op == "in" ? raw.split(",").map { |v| scalar(v.strip) } : scalar(raw.strip)
    { "field" => field, "op" => op, "value" => value }
  end

  # Booleans are true/false, numbers are integers, anything else is a string.
  def scalar(text)
    case text
    when "true" then true
    when "false" then false
    when /\A-?\d+\z/ then Integer(text, 10)
    else text
    end
  end

  def list(cell)
    cell.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # Roster table -> {"adjusters" => [...]}.
  def roster_hash(table)
    { "adjusters" => table.hashes.map do |row|
      {
        "id" => row.fetch("id"),
        "name" => row.fetch("name"),
        "active" => boolean(row.fetch("active")),
        "licensed_states" => list(row.fetch("licensed_states")),
        "skills" => list(row.fetch("skills")),
        "capacity" => Integer(row.fetch("capacity"), 10),
        "open_claims" => Integer(row.fetch("open_claims"), 10)
      }
    end }
  end

  # Claims table -> array of claim hashes. A blank cell means the field is absent.
  def claim_hashes(table)
    table.hashes.map do |row|
      row.each_with_object({}) do |(key, cell), claim|
        next if cell.nil? || cell.strip.empty?

        claim[key] =
          if CLAIM_INTEGER_FIELDS.include?(key) then Integer(cell.strip, 10)
          elsif key == "cat_event" then boolean(cell)
          else cell.strip
          end
      end
    end
  end

  def boolean(cell)
    case cell.strip
    when "true" then true
    when "false" then false
    else raise ArgumentError, "expected true or false, got #{cell.inspect}"
    end
  end

  # Replaces the condition on the same field in rule `rule_id` (appends if it has none).
  def replace_condition(rules_hash, rule_id, clause)
    rule = rules_hash["rules"].find { |r| r["id"] == rule_id }
    raise ArgumentError, "no rule #{rule_id.inspect} in the rules" unless rule

    new_condition = condition(clause)
    index = rule["conditions"].index { |c| c["field"] == new_condition["field"] }
    if index
      rule["conditions"][index] = new_condition
    else
      rule["conditions"] << new_condition
    end
    rules_hash
  end
end
