require "test_helper"

class PingsControllerTest < ActionDispatch::IntegrationTest
  setup { @monitor = monitors(:pending) }

  # Scenario 1 — 200 {"ok":true} + a PingEvent is created.
  test "GET /ping/:token returns 200 ok and records a PingEvent" do
    assert_difference -> { @monitor.ping_events.count }, 1 do
      get ping_path(@monitor.ping_token)
    end

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
  end

  # Scenario 2 — last_ping_at / next_due_at math.
  test "a ping sets last_ping_at to now and next_due_at to now + interval" do
    freeze_time do
      now = Time.current
      get ping_path(@monitor.ping_token)
      @monitor.reload

      assert_equal now, @monitor.last_ping_at
      assert_equal now + @monitor.expected_interval_seconds.seconds, @monitor.next_due_at
    end
  end

  # Scenario 3 — pending -> up.
  test "a ping transitions a pending monitor to up" do
    assert_equal "pending", @monitor.status
    get ping_path(@monitor.ping_token)
    assert_equal "up", @monitor.reload.status
  end

  # Scenario 4 — duration_ms captured from the query string.
  test "duration_ms query param is captured on the PingEvent" do
    get ping_path(@monitor.ping_token, duration_ms: 1234)

    assert_response :success
    assert_equal 1234, @monitor.ping_events.order(:received_at).last.duration_ms
  end

  # A non-numeric duration_ms must be ignored (stored as nil), never coerced to
  # 0 — String#to_i("abc") == 0 would silently corrupt latency data.
  test "a non-numeric duration_ms is stored as nil, not 0" do
    get ping_path(@monitor.ping_token, duration_ms: "abc")

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
    assert_nil @monitor.ping_events.order(:received_at).last.duration_ms
  end

  # Scenario 5 — unknown token -> opaque 404, no PingEvent.
  test "an unknown token returns 404 and creates no PingEvent" do
    assert_no_difference -> { PingEvent.count } do
      get ping_path("definitely-not-a-real-token")
    end

    assert_response :not_found
  end

  # Scenario 6 — POST behaves identically.
  test "POST /ping/:token behaves identically to GET" do
    assert_difference -> { @monitor.ping_events.count }, 1 do
      post ping_path(@monitor.ping_token)
    end

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
    assert_equal "up", @monitor.reload.status
  end

  # Scenario 7 — source_ip is set from the request.
  test "the ping records the request source_ip" do
    get ping_path(@monitor.ping_token)

    event = @monitor.ping_events.order(:received_at).last
    assert event.source_ip.present?
  end

  # CSRF is disabled in the test env by default, which hides a real production
  # bug: a machine POST has no authenticity token. Turn forgery protection on
  # for this one test to prove the endpoint is genuinely CSRF-exempt.
  test "POST works with forgery protection enabled (the endpoint is CSRF-exempt)" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post ping_path(@monitor.ping_token)

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
