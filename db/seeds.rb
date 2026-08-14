# Idempotent seed data: one user with one project, seeded the way a real one now
# comes into existence — through the setup command (v1-scope §7).
#
# The monitor is registered through Project::MonitorSync rather than created by
# hand, because that is the only path a monitor has in V1: the sync is the one
# writer of monitor config, and a hand-made row would seed a skeleton whose shape
# no user can reproduce.
#
# BOTH credentials are issued. Issuing only the API key seeds a project that can
# register monitors and never check one in — the permanently-grey-row failure §7
# exists to prevent.
#
#   bin/rails db:seed

user = User.find_or_create_by!(email_address: "demo@stablemate.dev") do |u|
  # A real (has_secure_password) credential so the demo account can sign in.
  u.password = "password1234"
  u.plan = "free"
end

project = user.projects.find_or_create_by!(name: "Demo app")

# Raw tokens exist only here, in this process — only their digests are stored —
# so they are printed once, exactly as the setup panel renders them once.
setup = project.issue_setup_pair!

project.sync_monitors(app: "demo-app", entries: [
  { registration_key: "nightly_backup", name: "Nightly backup",
    expected_interval_seconds: 1.day.to_i,
    grace_period_seconds: (1.day * Stablemate::DEFAULT_GRACE_FRACTION).to_i,
    schedule: "0 3 * * *" }
])

monitor = project.monitors.find_by!(registration_key: "nightly_backup")

puts "Seeded #{user.email_address} / #{project.name.inspect} / #{monitor.name.inspect}."
puts
puts "Wire up a host app with the same line the setup panel shows:"
puts "  bin/rails stablemate:install " \
     "STABLEMATE_API_KEY=#{setup.api_key_token} STABLEMATE_PING_KEY=#{setup.ping_key_token}"
puts
puts "Or check in by hand, the way the gem does — the credential rides the header,"
puts "never the URL, so it stays out of the logs:"
puts "  curl -X POST -H 'Authorization: Bearer #{setup.ping_key_token}' \\"
puts "    http://localhost:3000/api/v1/monitors/#{monitor.registration_key}/pings"
