require "test_helper"

# The V1 check-in endpoint (v1-scope §5). Addressed by task key, authenticated by
# a ping key in an Authorization header, POST only. Nothing here may be inherited
# from Api::V1::BaseController — that base authenticates an ApiKey.
class Api::V1::Monitors::PingsControllerTest < ActionDispatch::IntegrationTest
  PINGS = Api::V1::Monitors::PingsController

  setup do
    @project = users(:carol).projects.sole
    @monitor = register("daily_digest")
    _key, @raw = PingKey.issue(project: @project, name: "Production")
  end

  def auth(raw = @raw) = { "Authorization" => "Bearer #{raw}" }

  def register(key, project: @project, status: "pending")
    project.monitors.create!(name: key, registration_key: key, source: "gem", status:,
                             expected_interval_seconds: 3600, grace_period_seconds: 300)
  end

  def check_in(key = "daily_digest", params: {}, headers: auth)
    post api_v1_monitor_pings_path(key), params:, headers:
  end

  # --- The response contract (§5.4) -----------------------------------------

  test "a valid key and a known task records a check-in" do
    assert_difference -> { @monitor.ping_events.count }, 1 do
      check_in
    end

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
    assert_equal "up", @monitor.reload.status
  end

  test "a missing, unknown or revoked key is an identical opaque 401" do
    revoked, revoked_raw = PingKey.issue(project: @project, name: "Old")
    revoked.destroy

    [ {}, auth("sm_ping_nosuchkeynosuchkeynosuchkey00"), auth(revoked_raw) ].each do |headers|
      check_in(headers:)
      assert_response :unauthorized
      assert_equal({ "error" => "unauthorized" }, response.parsed_body)
    end
  end

  test "a malformed authorization header is a 401, not a 500" do
    check_in(headers: { "Authorization" => @raw })
    assert_response :unauthorized
  end

  test "a valid key and an unknown task is a 404" do
    check_in("no_such_task")
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
  end

  test "a failure ping records a failure and takes the monitor down" do
    check_in(params: { status: "1", message: "boom" })

    assert_response :success
    assert_equal "failure", @monitor.ping_events.sole.kind
    assert_equal "boom", @monitor.ping_events.sole.error
    assert_equal "down", @monitor.reload.status
  end

  test "a check-in on a down monitor resolves its incident and emails a recovery" do
    @monitor.update!(status: "down", last_ping_at: 2.hours.ago, next_due_at: 1.hour.ago)
    incident = @monitor.incidents.create!(started_at: 1.hour.ago)

    assert_emails 1 do
      perform_enqueued_jobs { check_in }
    end
    assert_not_nil incident.reload.resolved_at
    assert_equal "up", @monitor.reload.status
  end

  # --- Tenancy (§5.2) --------------------------------------------------------

  # The old ping token was unique across the whole database, so isolation was a
  # property of the schema. Task names are ordinary words, unique only within a
  # project — this scoping is now the only thing keeping tenants apart.
  test "the same task name in two projects never crosses" do
    other_project = users(:dave).projects.sole
    theirs = register("daily_digest", project: other_project)

    assert_no_difference -> { theirs.ping_events.count } do
      assert_difference -> { @monitor.ping_events.count }, 1 do
        check_in
      end
    end
    assert_equal "pending", theirs.reload.status
  end

  test "a ping key cannot check in against another project's monitor" do
    other_project = users(:dave).projects.sole
    register("their_task", project: other_project)

    check_in("their_task")
    assert_response :not_found
  end

  # --- Credential separation (§4, §12) ---------------------------------------

  # This controller sits in a directory where every sibling inherits the thing it
  # must not: a behavioural test is a snapshot, so assert on the class graph too.
  test "the check-in controller does not inherit the API-key base controller" do
    assert_not PINGS.ancestors.include?(Api::V1::BaseController),
               "PingsController must not inherit Api::V1::BaseController — that base " \
               "authenticates an ApiKey, and a suppressed before_action can be forgotten"
    assert_includes PINGS.ancestors, ActionController::API
  end

  test "an API key is rejected by the check-in endpoint" do
    _api_key, api_raw = ApiKey.issue(project: @project, name: "CI")

    assert_no_difference -> { @monitor.ping_events.count } do
      check_in(headers: auth(api_raw))
    end
    assert_response :unauthorized
    assert_equal({ "error" => "unauthorized" }, response.parsed_body)
  end

  test "a ping key is rejected by every management endpoint" do
    monitor = monitors(:up)

    get api_v1_monitors_path, headers: auth
    assert_response :unauthorized
    get api_v1_monitor_path(monitor), headers: auth
    assert_response :unauthorized
    post sync_api_v1_monitors_path, params: { app: "x", monitors: [] }, as: :json, headers: auth
    assert_response :unauthorized
    post rotate_api_v1_monitor_path(monitor), headers: auth
    assert_response :unauthorized
  end

  # --- Routing (§5.1) --------------------------------------------------------

  test "a dotted task name arrives intact" do
    register("reports.daily")

    assert_difference -> { @project.monitors.find_by(registration_key: "reports.daily").ping_events.count }, 1 do
      check_in("reports.daily")
    end
    assert_response :success
  end

  # Path parameters win over body parameters, so a body-supplied key cannot
  # redirect a check-in at another monitor. Worth a test rather than luck.
  test "a body-supplied registration_key cannot override the path" do
    other = register("other_task")

    assert_no_difference -> { other.ping_events.count } do
      check_in("daily_digest", params: { registration_key: "other_task" })
    end
    assert_response :success
    assert_equal 1, @monitor.ping_events.count
  end

  # A check-in advances the clock and, on a down monitor, resolves the incident and
  # emails "recovered" — so anything that follows a link (chat previews, mail
  # prefetch, scanners) must not be able to fire one.
  test "GET is not routed — a check-in has side effects a link prefetch must not fire" do
    assert_no_difference -> { @monitor.ping_events.count } do
      get "/api/v1/monitors/daily_digest/pings", headers: auth
    end
    assert_response :not_found
  end

  # --- Guards carried over from the public endpoint (§5.2) -------------------

  test "an out-of-range duration is dropped rather than rejecting the ping" do
    check_in(params: { duration_ms: 2_147_483_648 })

    assert_response :success
    assert_nil @monitor.ping_events.sole.duration_ms
  end

  test "a non-numeric duration is recorded as no measurement, never as zero" do
    check_in(params: { duration_ms: "soon" })

    assert_response :success
    assert_nil @monitor.ping_events.sole.duration_ms
  end

  # The controller's own comment blesses JSON ("Rails parses a JSON body into the
  # same params, so a JSON client works too"), and a JSON exit code is a NUMBER.
  # Dropped, it reads as a success: the job reported that it failed and the
  # monitor stays green forever — the one outcome this product exists to prevent.
  test "a JSON body's numeric status is read, not silently dropped as a success" do
    post api_v1_monitor_pings_path("daily_digest"),
         params: { status: 1, message: "boom" }.to_json,
         headers: auth.merge("Content-Type" => "application/json")

    assert_response :success
    assert_equal "failure", @monitor.ping_events.order(:created_at).last.kind
    assert_equal "down", @monitor.reload.status
  end

  test "a JSON body's numeric zero status is still a success" do
    post api_v1_monitor_pings_path("daily_digest"),
         params: { status: 0 }.to_json,
         headers: auth.merge("Content-Type" => "application/json")

    assert_equal "success", @monitor.ping_events.order(:created_at).last.kind
    assert_equal "up", @monitor.reload.status
  end

  # Kernel#Integer honours literal base prefixes, so a zero-padded duration is
  # read as octal. A wrapper doing `printf "%04d"` would have every latency it
  # reports silently rewritten, which is exactly the corruption the helper's
  # comment says it exists to prevent (it only guarded the to_i direction).
  test "a zero-padded duration is decimal, not octal" do
    check_in(params: { duration_ms: "0755" })

    assert_equal 755, @monitor.ping_events.order(:created_at).last.duration_ms
  end

  test "bracket-syntax parameters are ignored rather than stored as garbage" do
    check_in(params: { status: [ "1" ], message: { a: "b" } })

    assert_response :success
    assert_equal "success", @monitor.ping_events.sole.kind
  end

  # --- Everything is JSON, never HTML (§5.2) ---------------------------------

  # Without its own rescue_from an ActionController::API controller answers a full
  # HTML Rails error page. The gem classifies 422 as transient, absorbs it in the
  # grace period, and the monitor then goes down with an email saying it MISSED
  # its check-in — a server-side fault reaching the user as their job failing.
  test "a monitor that fails validation during check-in answers JSON, not HTML" do
    Monitoring::Monitor.where(id: @monitor.id).update_all(expected_interval_seconds: nil)

    check_in
    assert_response :unprocessable_entity
    assert_equal "application/json", response.media_type
    assert_equal({ "error" => "unprocessable_entity" }, response.parsed_body)
  end

  # --- Rate limiting (§5.3) --------------------------------------------------

  test "over the per-monitor limit answers the JSON 429 body, not the framework default" do
    with_ping_rate_limiting do
      (PINGS::PER_MONITOR_LIMIT + 1).times { check_in }
    end

    assert_response :too_many_requests
    assert_equal "application/json", response.media_type
    assert_equal({ "error" => "rate_limited" }, response.parsed_body)
  end

  # The first case alone would pass a lambda that reads only the task name.
  test "two task names under one key do not share a counter" do
    register("other_task")

    with_ping_rate_limiting do
      (PINGS::PER_MONITOR_LIMIT + 1).times { check_in }
      assert_response :too_many_requests

      check_in("other_task")
      assert_response :success
    end
  end

  # ...and this is what catches a lambda reading post-authentication state: an
  # ivar that does not exist yet at filter time is dropped by Rails' .compact,
  # collapsing the whole controller onto one counter.
  test "two keys on one task name do not share a counter" do
    _second, second_raw = PingKey.issue(project: @project, name: "Rotation")

    with_ping_rate_limiting do
      (PINGS::PER_MONITOR_LIMIT + 1).times { check_in }
      assert_response :too_many_requests

      check_in(headers: auth(second_raw))
      assert_response :success
    end
  end

  # The layer-order bug in §5.3: each layer increments unconditionally, but the
  # responder halts the chain, so only the layer that fires FIRST charges. Read
  # the per-IP counter directly — the behavioural version would take 300 requests
  # to reach the ceiling, and this is the exact property being pinned.
  test "a throttled monitor does not consume the shared per-IP budget" do
    over_by = 5

    with_ping_rate_limiting do
      (PINGS::PER_MONITOR_LIMIT + over_by).times { check_in }
      assert_response :too_many_requests

      assert_equal PINGS::PER_MONITOR_LIMIT, per_ip_count,
                   "requests rejected by the per-monitor layer must not be charged to the " \
                   "host-wide per-IP bucket — declare per-monitor FIRST"
    end
  end

  # Without a per-IP layer there is no pre-authentication bound at all: both
  # halves of the per-monitor key are attacker-chosen, so a flood mints a fresh
  # bucket per request and never trips.
  test "an unauthenticated flood is bounded" do
    with_ping_rate_limiting do
      PINGS::PER_IP_LIMIT.times do |i|
        check_in("task_#{i}", headers: {})
        assert_response :unauthorized
      end

      check_in("task_over", headers: {})
      assert_response :too_many_requests
    end
  end

  private
    def with_ping_rate_limiting
      PINGS::RATE_LIMIT_STORE.clear
      yield
    ensure
      PINGS::RATE_LIMIT_STORE.clear
    end

    def per_ip_count
      PINGS::RATE_LIMIT_STORE.read("rate-limit:#{PINGS.controller_path}:per-ip:127.0.0.1")
    end
end
