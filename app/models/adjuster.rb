# An adjuster and their authoritative open-claims counter (Q18). The engine decides;
# this model only reads the roster and moves the counter atomically (Q37).
class Adjuster < ApplicationRecord
  has_many :claims, dependent: :restrict_with_exception

  # What Engine#decide needs: any object that responds to #adjusters (see roster.rb).
  EngineRoster = Struct.new(:adjusters)

  # Claims a slot: UPDATE adjusters SET open_claims = open_claims + 1 WHERE id = ? AND
  # open_claims < capacity. Returns false when another request took the last slot.
  def self.take_slot(id)
    where(id: id).where("open_claims < capacity").update_all("open_claims = open_claims + 1") == 1
  end

  # Guarded release on re-dispatch: never drives the counter below 0 (Q37).
  def self.release_slot(id)
    where(id: id).where("open_claims > 0").update_all("open_claims = open_claims - 1") == 1
  end

  # The whole roster as the engine sees it, read fresh. `releasing` is the adjuster a
  # re-dispatch is about to release: their slot counts as free when choosing (Q18).
  def self.engine_roster(releasing: nil)
    EngineRoster.new(order(:id).map { |a| a.to_engine(releasing: a.id == releasing) })
  end

  # Upserts adjusters from a validated Dispatch::Roster (seeds, test setup). New adjusters
  # start at the roster's open_claims baseline. An adjuster already in the table keeps its
  # live counter (BUG-022): resetting it would free slots that real claims still hold, and
  # the capacity audit, which reads the counter, could not see the over-assignment.
  # Tests that replace the roster wholesale pass reset_open_claims: true.
  def self.load_roster!(roster, reset_open_claims: false)
    now = Time.current
    rows = roster.adjusters.map { |a| a.to_h.merge("created_at" => now, "updated_at" => now) }
    return if rows.empty?

    updated = Dispatch::Adjuster::KEYS + ["updated_at"] - ["id"]
    updated -= ["open_claims"] unless reset_open_claims
    upsert_all(rows, unique_by: :id, update_only: updated)
  end

  # Not Roster-validated: the stored counter can exceed capacity after a lost race, and
  # the engine must still treat that adjuster as full rather than refuse the roster.
  def to_engine(releasing: false)
    Dispatch::Adjuster.new(id: id, name: name, active: active, licensed_states: licensed_states, skills: skills,
                           capacity: capacity, open_claims: releasing ? [open_claims - 1, 0].max : open_claims)
  end

  # Full as the engine judges it; capacity 0 is always full (Q17).
  def at_capacity?
    to_engine.full?
  end
end
