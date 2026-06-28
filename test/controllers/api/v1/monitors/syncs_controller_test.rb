require "test_helper"

class Api::V1::Monitors::SyncsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:bob) # owns one fixture monitor
    _key, @raw = ApiKey.issue(user: @user, name: "CI")
  end

  def auth = { "Authorization" => "Bearer #{@raw}" }

  def sync(monitors)
    post sync_api_v1_monitors_url, params: { app: "my-app", monitors: }, as: :json, headers: auth
  end

  def entry(key, name: nil, interval: 3600, grace: 300)
    { registration_key: key, name: name || key,
      expected_interval_seconds: interval, grace_period_seconds: grace }
  end

  # Scenario 6 — new keys create gem/pending monitors and return ping_url.
  test "new registration keys create gem/pending monitors and return ping_url" do
    sync([ entry("daily_digest") ])
    assert_response :success

    body = JSON.parse(response.body)
    entry = body["monitors"].first
    assert_equal "daily_digest", entry["registration_key"]
    assert_equal "pending", entry["status"]
    assert entry["ping_url"].include?("/ping/")

    monitor = @user.monitors.find_by(registration_key: "daily_digest")
    assert_equal "gem", monitor.source
  end

  # Scenario 7 — idempotent upsert, no duplication.
  test "re-syncing updates and does not duplicate" do
    sync([ entry("daily_digest", name: "First", interval: 3600) ])
    assert_no_difference -> { @user.monitors.count } do
      sync([ entry("daily_digest", name: "Renamed", interval: 7200) ])
    end
    monitor = @user.monitors.find_by(registration_key: "daily_digest")
    assert_equal "Renamed", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
  end

  # Scenario 8 — cap overflow: partial register + skipped, still 200.
  test "cap overflow registers up to the cap and skips the rest with 200" do
    sync(%w[a b c d e f].map { |k| entry(k) })
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 4, body["monitors"].size
    assert_equal 2, body["skipped"].size
    assert_equal "limit_reached", body["skipped"].first["reason"]
  end

  # Scenario 9 — updates succeed at the cap.
  test "updates to existing monitors succeed at the cap" do
    sync((1..4).map { |i| entry("k#{i}") }) # bob now at 5 (1 fixture + 4)
    sync([ entry("k1", name: "Updated") ])
    assert_response :success
    assert_empty JSON.parse(response.body)["skipped"]
    assert_equal "Updated", @user.monitors.find_by(registration_key: "k1").name
  end

  # Scenario 10 — absent monitors untouched.
  test "monitors absent from the payload are left untouched" do
    sync([ entry("keep") ])
    before = @user.monitors.count
    sync([ entry("other") ])
    assert_equal before + 1, @user.monitors.count
    assert @user.monitors.exists?(registration_key: "keep")
  end

  # Scenario 11 — the returned ping_url actually works.
  test "the returned ping_url records a PingEvent when hit" do
    sync([ entry("daily_digest") ])
    url = JSON.parse(response.body)["monitors"].first["ping_url"]
    monitor = @user.monitors.find_by(registration_key: "daily_digest")

    assert_difference -> { monitor.ping_events.count }, 1 do
      post URI(url).path
    end
    assert_response :success
    assert_equal "up", monitor.reload.status
  end

  test "sync requires a bearer token" do
    post sync_api_v1_monitors_url, params: { monitors: [] }, as: :json
    assert_response :unauthorized
  end
end
