# Reads the Background tables of features/rule_change_gate.feature, so fixtures and
# shipped example files can be checked against the spec instead of drifting from it.
# Plain Ruby, no Cucumber: the table formats are those in STEP_GLOSSARY.md.
module GateBackground
  FEATURE = File.expand_path("../../features/rule_change_gate.feature", __dir__)

  module_function

  # The pipe table that follows the step line containing `step`, as row hashes.
  def table(step)
    lines = File.readlines(FEATURE, chomp: true)
    start = lines.index { |l| l.include?(step) } or raise ArgumentError, "step #{step.inspect} not found in #{FEATURE}"
    rows = lines.drop(start + 1).take_while { |l| l.strip.start_with?("|") }
                .map { |l| l.strip.delete_prefix("|").delete_suffix("|").split("|").map(&:strip) }
    header, *body = rows
    body.map { |row| header.zip(row).to_h }
  end

  def list(cell)
    cell.split(",").map(&:strip).reject(&:empty?)
  end

  def scalar(text)
    case text
    when "true" then true
    when "false" then false
    when /\A-?\d+\z/ then Integer(text, 10)
    else text
    end
  end

  # {"rules" => [...]} from the base rules table.
  def rules
    { "rules" => table('a rules file "base.json" with the dispatch rules:').map do |row|
      conditions = row["conditions"].split(";").map(&:strip).reject(&:empty?).map do |clause|
        field, op, raw = clause.split(/\s+/, 3)
        { "field" => field, "op" => op, "value" => op == "in" ? list(raw).map { |v| scalar(v) } : scalar(raw) }
      end
      { "id" => row["id"], "priority" => Integer(row["priority"], 10), "queue" => row["queue"],
        "required_skills" => list(row["required_skills"]), "conditions" => conditions }
    end }
  end

  # Adjuster hashes from the roster table.
  def roster
    table('an adjusters file "roster.json" with the adjuster roster:').map do |row|
      { "id" => row["id"], "name" => row["name"], "active" => row["active"] == "true",
        "licensed_states" => list(row["licensed_states"]), "skills" => list(row["skills"]),
        "capacity" => Integer(row["capacity"], 10), "open_claims" => Integer(row["open_claims"], 10) }
    end
  end

  # Claim hashes from the replay claims table; a blank vehicle_value is absent.
  def replay_claims
    table('a claims file "replay.json" with the claims:').map do |row|
      claim = { "claim_number" => row["claim_number"], "line_of_business" => row["line_of_business"],
                "estimated_loss" => Integer(row["estimated_loss"], 10) }
      claim["vehicle_value"] = Integer(row["vehicle_value"], 10) unless row["vehicle_value"].empty?
      claim.merge("cat_event" => row["cat_event"] == "true", "loss_state" => row["loss_state"])
    end
  end
end
