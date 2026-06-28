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

ActiveRecord::Schema[8.1].define(version: 2026_06_28_170227) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "incidents", force: :cascade do |t|
    t.string "cause", default: "missed_ping", null: false
    t.datetime "created_at", null: false
    t.bigint "monitor_id", null: false
    t.datetime "resolved_at"
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.index ["monitor_id"], name: "index_incidents_on_monitor_id"
    t.index ["monitor_id"], name: "index_incidents_on_monitor_id_open", unique: true, where: "(resolved_at IS NULL)"
  end

  create_table "monitors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "expected_interval_seconds"
    t.integer "grace_period_seconds"
    t.datetime "last_ping_at"
    t.string "monitor_type", default: "heartbeat", null: false
    t.string "name", null: false
    t.datetime "next_due_at"
    t.string "ping_token", null: false
    t.string "registration_key"
    t.string "source", default: "manual", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["next_due_at"], name: "index_monitors_on_next_due_at"
    t.index ["ping_token"], name: "index_monitors_on_ping_token", unique: true
    t.index ["status", "next_due_at"], name: "index_monitors_on_status_and_next_due_at"
    t.index ["user_id", "registration_key"], name: "index_monitors_on_user_and_registration_key", unique: true, where: "(registration_key IS NOT NULL)"
    t.index ["user_id"], name: "index_monitors_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.string "channel", default: "email", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "event", null: false
    t.bigint "incident_id"
    t.bigint "monitor_id", null: false
    t.datetime "updated_at", null: false
    t.index ["incident_id"], name: "index_notifications_on_incident_id"
    t.index ["monitor_id"], name: "index_notifications_on_monitor_id"
  end

  create_table "ping_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "kind", default: "success", null: false
    t.bigint "monitor_id", null: false
    t.datetime "received_at", null: false
    t.string "source_ip"
    t.index ["monitor_id"], name: "index_ping_events_on_monitor_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.string "plan", default: "free", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index "lower((email_address)::text)", name: "index_users_on_lower_email_address", unique: true
  end

  add_foreign_key "incidents", "monitors"
  add_foreign_key "monitors", "users"
  add_foreign_key "notifications", "incidents"
  add_foreign_key "notifications", "monitors"
  add_foreign_key "ping_events", "monitors"
  add_foreign_key "sessions", "users"
end
