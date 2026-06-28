require "test_helper"

class MonitorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @alices = monitors(:up)
    @bobs = monitors(:bobs)
  end

  # Scenario 3 — protected routes redirect anonymous users to sign in.
  test "anonymous users are redirected to sign in" do
    get monitors_path
    assert_redirected_to new_session_path
  end

  # Scenario 6 — dashboard lists only the current user's monitors.
  test "index lists only the current user's monitors" do
    sign_in @alice
    get monitors_path

    assert_response :success
    assert_match @alices.name, response.body
    refute_match @bobs.name, response.body
  end

  # Scenario 5 — cross-tenant access is impossible (404, not 403, no leak).
  test "a user cannot show another user's monitor" do
    sign_in @alice
    get monitor_path(@bobs)
    assert_response :not_found
  end

  test "a user cannot edit another user's monitor" do
    sign_in @alice
    get edit_monitor_path(@bobs)
    assert_response :not_found
  end

  test "a user cannot update another user's monitor" do
    sign_in @alice
    patch monitor_path(@bobs), params: { monitor: { name: "hijacked" } }
    assert_response :not_found
    assert_equal "Bobs job", @bobs.reload.name
  end

  test "a user cannot destroy another user's monitor" do
    sign_in @alice
    assert_no_difference -> { Monitoring::Monitor.count } do
      delete monitor_path(@bobs)
    end
    assert_response :not_found
  end

  # Scenario 7 — create stores seconds, generates token, manual + pending.
  test "create makes a manual, pending monitor with a token" do
    sign_in @bob
    @bob.monitors.delete_all

    assert_difference -> { @bob.monitors.count }, 1 do
      post monitors_path, params: { monitor: { name: "API health", expected_interval_seconds: 300, grace_period_seconds: 60 } }
    end

    monitor = @bob.monitors.order(:created_at).last
    assert_redirected_to monitor_path(monitor)
    assert_equal "manual", monitor.source
    assert_equal "pending", monitor.status
    assert_equal 300, monitor.expected_interval_seconds
    assert monitor.ping_token.present?
  end

  # Scenario 8 (request) — creating past the cap re-renders with an error.
  test "creating a monitor at the cap is rejected" do
    sign_in @bob
    @bob.monitors.delete_all
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @bob.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300) }

    assert_no_difference -> { @bob.monitors.count } do
      post monitors_path, params: { monitor: { name: "Over", expected_interval_seconds: 3600, grace_period_seconds: 300 } }
    end
    assert_response :unprocessable_entity
  end

  # Scenario 13 (request) — destroy removes the monitor.
  test "destroy removes the owner's monitor" do
    sign_in @alice
    assert_difference -> { @alice.monitors.count }, -1 do
      delete monitor_path(@alices)
    end
    assert_redirected_to monitors_path
  end
end
