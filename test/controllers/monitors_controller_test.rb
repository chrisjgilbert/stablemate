require "test_helper"

class MonitorsControllerTest < ActionDispatch::IntegrationTest
  # Scenario 10 — JSON status read reflects current state.
  test "GET /monitors/:id.json returns the monitor's status fields" do
    monitor = monitors(:up)

    get monitor_path(monitor, format: :json)

    assert_response :success
    body = response.parsed_body
    assert_equal monitor.id, body["id"]
    assert_equal monitor.name, body["name"]
    assert_equal monitor.status, body["status"]
    assert_equal monitor.last_ping_at.iso8601(3), Time.parse(body["last_ping_at"]).utc.iso8601(3)
    assert_equal monitor.next_due_at.iso8601(3), Time.parse(body["next_due_at"]).utc.iso8601(3)
  end

  test "the JSON read exposes only the documented fields" do
    get monitor_path(monitors(:up), format: :json)

    assert_equal %w[id name status last_ping_at next_due_at].sort,
                 response.parsed_body.keys.sort
  end
end
