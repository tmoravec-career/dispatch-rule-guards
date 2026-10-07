# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_10_06_090000) do
  create_table "adjusters", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.json "licensed_states", default: [], null: false
    t.json "skills", default: [], null: false
    t.integer "capacity", null: false
    t.integer "open_claims", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "claims", force: :cascade do |t|
    t.string "claim_number", limit: 32, null: false
    t.string "line_of_business", null: false
    t.integer "estimated_loss", null: false
    t.integer "vehicle_value"
    t.boolean "cat_event", default: false, null: false
    t.string "loss_state", null: false
    t.string "status", null: false
    t.string "queue", null: false
    t.string "matched_rule"
    t.string "adjuster_id"
    t.string "reason_code", null: false
    t.text "reason", null: false
    t.integer "dispatch_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["adjuster_id"], name: "index_claims_on_adjuster_id"
    t.index ["claim_number"], name: "index_claims_on_claim_number", unique: true
    t.index ["created_at", "id"], name: "index_claims_on_created_at_and_id"
    t.index ["loss_state"], name: "index_claims_on_loss_state"
    t.index ["queue", "status"], name: "index_claims_on_queue_and_status"
    t.index ["status"], name: "index_claims_on_status"
  end

  create_table "dispatch_events", force: :cascade do |t|
    t.integer "claim_id", null: false
    t.integer "sequence", null: false
    t.string "event_id", null: false
    t.string "event", null: false
    t.datetime "occurred_at", null: false
    t.string "status", null: false
    t.string "queue", null: false
    t.string "matched_rule"
    t.string "adjuster_id"
    t.string "reason_code", null: false
    t.text "reason", null: false
    t.text "payload", null: false
    t.string "webhook_status", default: "pending", null: false
    t.integer "webhook_response_code"
    t.string "webhook_error"
    t.datetime "webhook_attempted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["claim_id", "sequence"], name: "index_dispatch_events_on_claim_id_and_sequence", unique: true
    t.index ["claim_id"], name: "index_dispatch_events_on_claim_id"
    t.index ["event_id"], name: "index_dispatch_events_on_event_id", unique: true
  end

  add_foreign_key "claims", "adjusters"
  add_foreign_key "dispatch_events", "claims"
end
