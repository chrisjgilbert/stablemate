require "test_helper"

# Scenario 11 — the walking-skeleton proof in one test: a real ping travels
# end-to-end and the status read shows the timestamp move.
class WalkingSkeletonTest < ActionDispatch::IntegrationTest
  test "a ping moves the monitor's timestamp and the status read reflects it" do
    user = User.create!(email_address: "skeleton@example.com", password_digest: "x", plan: "free")
    monitor = user.monitors.create!(name: "End-to-end", expected_interval_seconds: 3600)

    assert_nil monitor.last_ping_at
    assert_equal "pending", monitor.status

    freeze_time do
      now = Time.current

      # 1. Ping the public URL.
      get ping_path(monitor.ping_token)
      assert_response :success
      assert_equal({ "ok" => true }, response.parsed_body)

      # 2. Read the status back.
      get monitor_path(monitor, format: :json)
      assert_response :success
      body = response.parsed_body

      assert_equal "up", body["status"]
      assert_equal now.iso8601(3), Time.parse(body["last_ping_at"]).utc.iso8601(3)
      assert_equal (now + 3600.seconds).iso8601(3), Time.parse(body["next_due_at"]).utc.iso8601(3)
    end

    assert_equal 1, monitor.ping_events.count
  end
end
