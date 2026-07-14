require "test_helper"

class MonitorsControllerTest < ActionDispatch::IntegrationTest
  include MonitorsHelper

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

  # README DoD — the dashboard sparklines must not N+1: the mini-ticks query
  # count is constant whether there are 2 monitors or 4 (one batched query, not
  # one per row).
  test "index loads sparkline ticks without an N+1 (constant queries as rows grow)" do
    sign_in @alice
    @alice.monitors.destroy_all # start clean within the per-user cap
    2.times do |i|
      @alice.monitors.create!(name: "extra-#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300)
    end

    counts = lambda do
      n = 0
      callback = ->(*, payload) { n += 1 if payload[:sql] =~ /ping_events/i && payload[:name] != "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get monitors_path }
      n
    end

    baseline = counts.call
    @alice.monitors.create!(name: "another", expected_interval_seconds: 3600, grace_period_seconds: 300)
    assert_equal baseline, counts.call, "adding a monitor must not add a ping_events query"
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

  # Caps OFF (issue #16): with no cap configured, creating past the old limit is
  # allowed through the UI create path.
  test "with the cap OFF, creating past the old limit is allowed" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      sign_in @bob
      @bob.monitors.delete_all
      6.times { |i| @bob.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300) }

      assert_difference -> { @bob.monitors.count }, 1 do
        post monitors_path, params: { monitor: { name: "Seventh", expected_interval_seconds: 3600, grace_period_seconds: 300 } }
      end
      assert_response :redirect
    end
  end

  # Scenario 13 (request) — destroy removes the monitor.
  test "destroy removes the owner's monitor" do
    sign_in @alice
    assert_difference -> { @alice.monitors.count }, -1 do
      delete monitor_path(@alices)
    end
    assert_redirected_to monitors_path
  end

  # "Next check" surfaces next_due_at for an actively-up monitor: a compact
  # countdown on the crowded dashboard row, the exact timestamp (plus a grace
  # note when a grace period is actually configured) on the detail page.
  test "index shows a compact next-check countdown, show shows the exact time with a grace note" do
    sign_in @alice

    get monitors_path
    assert_response :success
    assert_match "next in #{humanize_duration_until(@alices.next_due_at)}", response.body

    get monitor_path(@alices)
    assert_response :success
    assert_select "[data-testid='next-check']"
    assert_select "[data-testid='next-check-grace']"
  end

  test "show hides the grace note when grace_period_seconds is 0" do
    monitor = create_monitor(status: "up", next_due_at: 50.minutes.from_now, grace_period_seconds: 0)
    sign_in @alice
    get monitor_path(monitor)

    assert_response :success
    assert_select "[data-testid='next-check']"
    assert_select "[data-testid='next-check-grace']", false
  end

  test "index and show omit next-check for a monitor that has never been pinged" do
    sign_in @alice
    assert_no_next_check(monitors(:pending))
  end

  test "index and show omit next-check for down, paused, and suspended monitors" do
    sign_in @alice
    @alice.monitors.delete_all # stay within the per-user cap

    %w[down paused suspended].each do |status|
      assert_no_next_check create_monitor(status:, next_due_at: 50.minutes.from_now)
    end
  end

  # A monitor stays "up" (not yet swept to down) for the whole grace window
  # after next_due_at passes — next_due_at is stale during that window, so it
  # must not render as though it's still upcoming.
  test "index and show omit next-check once next_due_at has passed, even while still up and within grace" do
    sign_in @alice
    assert_no_next_check create_monitor(status: "up", next_due_at: 2.minutes.ago, last_ping_at: 2.hours.ago)
  end

  # "last seen" pairs with "next in" on the crowded dashboard row (both
  # compact, both labeled) instead of the old bare, verbose "X minutes ago".
  test "index shows last seen for a pinged monitor and never seen for one that hasn't been" do
    sign_in @alice
    get monitors_path

    assert_response :success
    assert_match "last seen #{humanize_duration_since(@alices.last_ping_at)} ago", response.body
    assert_match "never seen", response.body
  end

  private
    def create_monitor(status:, next_due_at:, grace_period_seconds: 300, last_ping_at: 10.minutes.ago)
      @alice.monitors.create!(name: "#{status.capitalize} monitor", expected_interval_seconds: 3600,
                               grace_period_seconds:, status:, last_ping_at:, next_due_at:)
    end

    def assert_no_next_check(monitor)
      get monitors_path
      assert_select "##{ActionView::RecordIdentifier.dom_id(monitor, :row)}" do
        assert_select "[data-testid='next-check']", false
      end

      get monitor_path(monitor)
      assert_select "[data-testid='next-check']", false
    end
end
