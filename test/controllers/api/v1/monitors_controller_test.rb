require "test_helper"

class Api::V1::MonitorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
    @project = @user.projects.sole
    @api_key, @raw = ApiKey.issue(project: @project, name: "CI")
  end

  def auth(token = @raw)
    { "Authorization" => "Bearer #{token}" }
  end

  test "valid bearer token authorizes and touches last_used_at" do
    assert_nil @api_key.last_used_at
    get api_v1_monitors_url, headers: auth
    assert_response :success
    assert_not_nil @api_key.reload.last_used_at
  end

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
    limit = Api::V1::BaseController::PER_KEY_LIMIT
    limit.times do
      get api_v1_monitors_url, headers: auth
      assert_response :success
    end

    get api_v1_monitors_url, headers: auth
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error"]
  end

  # M10 — the per-key layer is keyed on the caller-supplied Authorization header,
  # so an enumerating scanner mints a fresh bucket with every made-up token and
  # that layer alone never bounds it. The per-IP layer bounds the client whatever
  # it presents; it sits ahead of authentication, so unauthenticated traffic is
  # throttled without a database lookup.
  test "the API rate-limits one IP enumerating many made-up tokens" do
    limit = Api::V1::BaseController::PER_IP_LIMIT

    limit.times do |i|
      get api_v1_monitors_url, headers: auth("sm_live_madeup#{i}")
      assert_response :unauthorized
    end

    get api_v1_monitors_url, headers: auth("sm_live_madeup_over_the_limit")
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error"]

    # One bucket for the whole client, not one per presented token: a request
    # with a perfectly valid key (its own per-key bucket untouched) is throttled
    # by the same IP bound.
    get api_v1_monitors_url, headers: auth
    assert_response :too_many_requests
  end

  # `by:` is written into the store as the literal cache key and emitted into an
  # ActiveSupport::Notifications payload on every throttle, so it must never be
  # the credential itself (v1-scope §5.3).
  test "the per-key limiter buckets on a digest, never on the raw credential" do
    get api_v1_monitors_url, headers: auth
    assert_response :success

    store = Api::V1::BaseController::RATE_LIMIT_STORE
    scope = "rate-limit:api/v1/monitors:per-key"
    assert_equal 1, store.read("#{scope}:#{Digest::SHA256.hexdigest("Bearer #{@raw}")}")
    assert_nil store.read("#{scope}:Bearer #{@raw}")
  end

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
    assert_includes monitor["ping_url"], "/ping/"
    assert monitor.key?("status")
    assert monitor.key?("next_due_at")
  end

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

  # projects.md §9 (Design B) — a key scopes to ONE project. A monitor in ANOTHER
  # project of the SAME user is invisible: excluded from the index and an opaque
  # 404 on show. This proves the collision fix isolates the READ path, not just
  # writes (the read-cache collision §5 warns about).
  test "a key cannot see another project of the same user" do
    other = @user.projects.create!(name: "Other app")
    other_monitor = other.monitors.create!(
      name: "OtherProjectMonitor", expected_interval_seconds: 3600, grace_period_seconds: 300
    )

    get api_v1_monitor_url(other_monitor), headers: auth
    assert_response :not_found

    get api_v1_monitors_url, headers: auth
    names = JSON.parse(response.body)["monitors"].map { |m| m["name"] }
    refute_includes names, "OtherProjectMonitor"
    assert_includes names, monitors(:up).name
  end
end
