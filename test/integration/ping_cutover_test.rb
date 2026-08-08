require "test_helper"

# The phase gate (v1-scope §8.1). Phase 1 is additive: the new check-in endpoint,
# the ping key and the retired status all land, but a host still running the old
# gem keeps checking in through /ping/:ping_token and must not notice.
#
# Shipping both halves at once is what takes every healthy monitor dark: the old
# gem's cached address 404s, its re-sync 500s on the deleted ping_url helper, and
# a 15-minute job goes down inside 20 minutes. This test is what proves the two
# phases are separable, so it asserts on the OLD path continuing to work while
# every new surface exists alongside it.
class PingCutoverTest < ActionDispatch::IntegrationTest
  setup do
    @project = users(:carol).projects.sole
    _key, @api_raw = ApiKey.issue(project: @project, name: "CI")
  end

  def sync(entries)
    post sync_api_v1_monitors_url, params: { app: "my-app", monitors: entries }, as: :json,
         headers: { "Authorization" => "Bearer #{@api_raw}" }
  end

  test "an old gem's registration still receives a working ping URL" do
    sync([ { registration_key: "daily_digest", name: "daily_digest",
             expected_interval_seconds: 3600, grace_period_seconds: 300 } ])
    assert_response :success

    url = response.parsed_body["monitors"].sole["ping_url"]
    assert_includes url, "/ping/"

    monitor = @project.monitors.sole
    assert_difference -> { monitor.ping_events.count }, 1 do
      post URI(url).path
    end
    assert_response :success
    assert_equal "up", monitor.reload.status
  end

  # The casualties of a botched cutover are precisely the healthy monitors:
  # `detectable` is where(status: "up"), so a monitor whose pings silently stop
  # is the one the sweep flags. Keep pinging the old way and nothing fires.
  test "a monitor checking in the old way does not go overdue" do
    monitor = @project.monitors.create!(
      name: "hourly_sync", registration_key: "hourly_sync", source: "gem", status: "up",
      expected_interval_seconds: 3600, grace_period_seconds: 300,
      last_ping_at: 30.minutes.ago, next_due_at: 30.minutes.from_now
    )

    travel_to 90.minutes.from_now do
      post ping_path(monitor.ping_token)
      assert_response :success

      # Scoped to this monitor rather than to the mailbox: the sweep is global and
      # the fixture monitors of other tenants go overdue at +90 minutes too.
      perform_enqueued_jobs { DetectMissedPingsJob.perform_now }
    end

    assert_equal "up", monitor.reload.status
    assert_empty monitor.incidents
    assert_empty monitor.notifications
  end

  # Both addresses reach the same monitor, and neither route shadows the other:
  # /ping/:ping_token and /api/v1/monitors/:registration_key/pings coexist for the
  # whole of phase 1.
  test "the old and new check-in paths both work on the same monitor" do
    monitor = @project.monitors.create!(
      name: "daily_digest", registration_key: "daily_digest", source: "gem",
      expected_interval_seconds: 3600, grace_period_seconds: 300
    )
    _ping_key, ping_raw = PingKey.issue(project: @project, name: "Production")

    assert_difference -> { monitor.ping_events.count }, 2 do
      post ping_path(monitor.ping_token)
      assert_response :success

      post api_v1_monitor_pings_path("daily_digest"),
           headers: { "Authorization" => "Bearer #{ping_raw}" }
      assert_response :success
    end
  end

  # A ping key must not open the old door either — that endpoint's credential is
  # still the ping_token, and nothing about phase 1 widens it.
  test "the old endpoint still answers only to a ping token" do
    _ping_key, ping_raw = PingKey.issue(project: @project, name: "Production")

    post ping_path(ping_raw)
    assert_response :not_found
  end
end
