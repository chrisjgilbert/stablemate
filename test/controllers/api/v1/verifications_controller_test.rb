require "test_helper"

# GET /api/v1/verify (v1-scope §5.5) — proves a ping key end to end without
# recording a check-in, which is the honest fragment carved out of the rejected
# "preview ping": a synthetic check-in would assert a job ran when it never has.
class Api::V1::VerificationsControllerTest < ActionDispatch::IntegrationTest
  VERIFY = Api::V1::VerificationsController

  setup do
    @project = users(:carol).projects.sole
    @monitor = @project.monitors.create!(name: "daily_digest", registration_key: "daily_digest",
                                         source: "gem", expected_interval_seconds: 3600,
                                         grace_period_seconds: 300)
    _key, @raw = PingKey.issue(project: @project, name: "Production")
  end

  def auth(raw = @raw) = { "Authorization" => "Bearer #{raw}" }

  test "a ping key gets 200 ok" do
    get api_v1_verify_path, headers: auth

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
  end

  # No monitor is read, no event written. The key's own coarsened last_used_at
  # write is permitted and WILL fire on a fresh key's first verify, so this
  # asserts on the monitor's state rather than "no writes at all".
  test "verifying records nothing about any monitor" do
    before = @monitor.attributes

    assert_no_difference [ -> { PingEvent.count }, -> { Incident.count }, -> { Notification.count } ] do
      get api_v1_verify_path, headers: auth
    end

    assert_response :success
    assert_equal before, @monitor.reload.attributes
  end

  test "an API key, a revoked key and no key are the same opaque 401" do
    _api_key, api_raw = ApiKey.issue(project: @project, name: "CI")
    revoked, revoked_raw = PingKey.issue(project: @project, name: "Old")
    revoked.destroy

    [ {}, auth(api_raw), auth(revoked_raw), auth("sm_ping_nope") ].each do |headers|
      get api_v1_verify_path, headers: headers
      assert_response :unauthorized
      assert_equal({ "error" => "unauthorized" }, response.parsed_body)
    end
  end

  # §5.2's structural rule applies here too: this base authenticates a PingKey.
  test "the verify controller does not inherit the API-key base controller" do
    assert_not VERIFY.ancestors.include?(Api::V1::BaseController)
    assert_includes VERIFY.ancestors, ActionController::API
  end

  test "it is bounded by its own per-IP limit and answers the JSON 429 body" do
    with_ping_rate_limiting do
      VERIFY::PER_IP_LIMIT.times do
        get api_v1_verify_path, headers: auth
        assert_response :success
      end

      get api_v1_verify_path, headers: auth
    end

    assert_response :too_many_requests
    assert_equal "application/json", response.media_type
    assert_equal({ "error" => "rate_limited" }, response.parsed_body)
  end

  # "Sibling controller" is pinned deliberately: Rails scopes a limiter by
  # controller_path, so a verify flood must not eat the check-in path's budget.
  test "verify's own budget is separate from the check-in endpoint's" do
    with_ping_rate_limiting do
      VERIFY::PER_IP_LIMIT.times { get api_v1_verify_path, headers: auth }
      get api_v1_verify_path, headers: auth
      assert_response :too_many_requests

      post api_v1_monitor_pings_path("daily_digest"), headers: auth
      assert_response :success
    end
  end

  private
    def with_ping_rate_limiting
      PingKeyAuthentication::RATE_LIMIT_STORE.clear
      yield
    ensure
      PingKeyAuthentication::RATE_LIMIT_STORE.clear
    end
end
