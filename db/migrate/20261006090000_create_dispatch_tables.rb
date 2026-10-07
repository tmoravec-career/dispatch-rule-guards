# Adjusters with their stored open-claims counter (Q18), claims with their latest
# dispatch result, and the dispatch history (Q19), one row per webhook event.
class CreateDispatchTables < ActiveRecord::Migration[7.2]
  def change
    # The adjuster's ID ("ADJ-004") is the primary key, so the capacity claim is literally
    # UPDATE adjusters SET open_claims = open_claims + 1 WHERE id = ? AND open_claims < capacity (Q37).
    create_table :adjusters, id: :string do |t|
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.json :licensed_states, null: false, default: []
      t.json :skills, null: false, default: []
      t.integer :capacity, null: false
      t.integer :open_claims, null: false, default: 0
      t.timestamps
    end

    create_table :claims do |t|
      t.string :claim_number, null: false, limit: 32, index: { unique: true }
      t.string :line_of_business, null: false
      t.integer :estimated_loss, null: false
      t.integer :vehicle_value
      t.boolean :cat_event, null: false, default: false
      t.string :loss_state, null: false

      # The latest dispatch result. dispatch_count is also the latest event's sequence (Q47).
      t.string :status, null: false
      t.string :queue, null: false
      t.string :matched_rule
      t.references :adjuster, type: :string, foreign_key: true
      t.string :reason_code, null: false
      t.text :reason, null: false
      t.integer :dispatch_count, null: false, default: 0
      t.timestamps

      t.index [:queue, :status]
      t.index :status
      t.index :loss_state
      t.index [:created_at, :id]
    end

    create_table :dispatch_events do |t|
      t.references :claim, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.string :event_id, null: false, index: { unique: true }
      t.string :event, null: false
      t.datetime :occurred_at, null: false
      t.string :status, null: false
      t.string :queue, null: false
      t.string :matched_rule
      t.string :adjuster_id
      t.string :reason_code, null: false
      t.text :reason, null: false

      # The exact bytes sent, so a redelivery reuses the event ID and body (Q45, Q46).
      t.text :payload, null: false
      t.string :webhook_status, null: false, default: "pending"
      t.integer :webhook_response_code
      t.string :webhook_error
      t.datetime :webhook_attempted_at
      t.timestamps

      t.index [:claim_id, :sequence], unique: true
    end
  end
end
