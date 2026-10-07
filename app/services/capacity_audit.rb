# The capacity backstop (Q37, Q40): names every adjuster, active or not, whose stored
# open_claims exceeds capacity. Exit status 0 = clean, 1 = violations.
class CapacityAudit
  Violation = Struct.new(:adjuster_id, :open_claims, :capacity)

  def violations
    Adjuster.where("open_claims > capacity").order(:id).pluck(:id, :open_claims, :capacity).map { |row| Violation.new(*row) }
  end

  # Prints a summary line and one VIOLATION line per over-assigned adjuster.
  def run(out = $stdout)
    found = violations
    out.puts "Capacity audit: #{Adjuster.count} adjusters checked, #{found.size} over capacity"
    found.each do |v|
      out.puts "VIOLATION adjuster=#{v.adjuster_id} open_claims=#{v.open_claims} capacity=#{v.capacity}"
    end
    found.empty? ? 0 : 1
  end
end
