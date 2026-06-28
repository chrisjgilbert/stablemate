# Idempotent seed data: one user with one heartbeat monitor, so the walking
# skeleton can be exercised end-to-end (ping the URL, read the status).
#
#   bin/rails db:seed
#   curl http://localhost:3000/ping/<ping_token>

user = User.find_or_create_by!(email_address: "demo@stablemate.dev") do |u|
  # A real (has_secure_password) credential so the demo account can sign in.
  u.password = "password1234"
  u.plan = "free"
end

monitor = user.monitors.find_or_create_by!(name: "Nightly backup") do |m|
  m.monitor_type = "heartbeat"
  m.expected_interval_seconds = 1.day.to_i
  m.grace_period_seconds = (1.day * Stablemate::DEFAULT_GRACE_FRACTION).to_i
  m.source = "manual"
end

puts "Seeded user #{user.email_address} and monitor #{monitor.name.inspect}."
puts "Ping it: curl http://localhost:3000/ping/#{monitor.ping_token}"
