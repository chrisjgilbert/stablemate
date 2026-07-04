require "test_helper"

class Api::V1::MonitorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
    @api_key, @raw = ApiKey.issue(user: @user, name: "CI")
  end

  def auth(token = @raw)
    { "Authorization" => "Bearer #{token}" }
  end

  # Scenario 3 — a valid bearer resolves the tenant and touches last_used_at.
  test "valid bearer token authorizes and touches last_used_at" do
    assert_nil @api_key.last_used_at
    get api_v1_monitors_url, headers: auth
    assert_response :success
    assert_not_nil @api_key.reload.last_used_at
  end

  # Scenario 4 — missing/invalid/revoked -> opaque 401.
  test "missing token is 401" do
    get api_v1_monitors_url
    assert_response :unauthorized
  end

  test "invalid token is 401" do
    get api_v1_monitors_url, headers: auth("sm_live_nopenopenopenopenopenopenope")
    assert_response :unauthorized
  end

  test "revoked (destroyed) key is 401" do
    @api_key.destroy
    get api_v1_monitors_url, headers: auth
    assert_response :unauthorized
  end

  # WU-9 (M7) — the bearer API is rate-limited so a compromised/buggy key can't
  # hammer it; over-limit returns an opaque 429, and a healthy cadence is untouched.
  test "the API rate-limits a token over the ceiling with an opaque 429" do
    limit = 120
    limit.times do
      get api_v1_monitors_url, headers: auth
      assert_response :success
    end

    get api_v1_monitors_url, headers: auth
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error"]
  end

  # Scenario 5 — index returns only the authenticated user's monitors.
  test "index is tenant-scoped" do
    get api_v1_monitors_url, headers: auth
    body = JSON.parse(response.body)
    keys = body["monitors"].map { |m| m["name"] }
    assert_includes keys, monitors(:up).name
    refute_includes keys, monitors(:bobs).name
  end

  test "index includes ping_url and status fields" do
    get api_v1_monitors_url, headers: auth
    monitor = JSON.parse(response.body)["monitors"].first
    assert monitor["ping_url"].include?("/ping/")
    assert monitor.key?("status")
    assert monitor.key?("next_due_at")
  end

  # Scenario 13 — show returns the monitor + current status.
  test "show returns the monitor with current status" do
    get api_v1_monitor_url(monitors(:up)), headers: auth
    body = JSON.parse(response.body)
    assert_equal "up", body["status"]
    assert body.key?("uptime_percent")
    assert body.key?("expected_interval_seconds")
  end

  test "show of a foreign monitor is 404 (opaque)" do
    get api_v1_monitor_url(monitors(:bobs)), headers: auth
    assert_response :not_found
  end
end
