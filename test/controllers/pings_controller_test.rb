require "test_helper"

class PingsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { @monitor = monitors(:pending) }

  # Scenario 24 (request) — a ping recovers a down monitor and sends recovery mail.
  test "a ping recovers a down monitor, resolves its incident, sends one recovery email" do
    down = monitors(:up)
    down.update!(next_due_at: 10.minutes.ago) # overdue, so detection flags it
    down.flag_missed!
    assert down.down?

    assert_enqueued_emails 1 do
      get ping_path(down.ping_token)
    end

    assert_response :success
    assert down.reload.up?
    refute down.incidents.open.exists?
  end

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

  # Issue #19 — pinging a suspended (plan-downgraded) monitor via the public
  # endpoint records the event but must NOT flip it back to `up`: that would
  # re-enter the cap count and resume free monitoring after a downgrade. The
  # response stays the opaque 200 (the token never leaks monitor state).
  test "a ping on a suspended monitor records the event but leaves it suspended" do
    suspended = monitors(:up)
    suspended.suspend!

    assert_difference -> { suspended.ping_events.count }, 1 do
      assert_enqueued_emails 0 do
        get ping_path(suspended.ping_token)
      end
    end

    assert_response :success
    assert suspended.reload.suspended?
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

  # Scenario 7 — pinging a known token faster than the limit returns 429 after the
  # threshold; the ping hot path is otherwise unchanged.
  test "pinging a token over the per-token limit returns 429" do
    with_rate_limiting do
      limit = PingsController::PER_TOKEN_LIMIT

      limit.times do
        get ping_path(@monitor.ping_token)
        assert_response :success
      end

      get ping_path(@monitor.ping_token)
      assert_response :too_many_requests
    end
  end

  test "normal cron cadence is never throttled" do
    with_rate_limiting do
      # A handful of pings well under the threshold all succeed.
      3.times do
        get ping_path(@monitor.ping_token)
        assert_response :success
      end
    end
  end

  # Scenario 8 — repeated unknown-token requests are rate-limited per IP and always
  # return 404 (never a 429 that would distinguish a real token from a fake one,
  # and never 200).
  test "repeated unknown-token requests are rate-limited per IP but still 404" do
    with_rate_limiting do
      limit = PingsController::PER_IP_LIMIT

      # Drive the per-IP limit with unknown tokens; every response stays 404.
      (limit + 1).times do |i|
        get ping_path("scan-token-#{i}")
        assert_response :not_found
      end
    end
  end

  # --- Error notices (job-failure-details.md §6) ----------------------------

  # A non-zero status flips the monitor down immediately with one down email;
  # the response is the same 200 as a success ping.
  test "status=1 records a failure, flips the monitor down, and sends one down email" do
    up = monitors(:up)

    assert_enqueued_emails 1 do
      get ping_path(up.ping_token, status: 1, message: "RuntimeError: boom")
    end

    assert_response :success
    assert_equal({ "ok" => true }, response.parsed_body)
    assert up.reload.down?
    event = up.ping_events.order(:received_at).last
    assert_equal "failure", event.kind
    assert_equal "RuntimeError: boom", event.error
    assert_equal "RuntimeError: boom", up.incidents.open.sole.error
  end

  test "the s and m aliases behave like status and message" do
    up = monitors(:up)
    get ping_path(up.ping_token, s: 1, m: "boom")

    assert_response :success
    assert up.reload.down?
    assert_equal "boom", up.ping_events.order(:received_at).last.error
  end

  # status wins when both spellings are sent.
  test "status=0 beats s=1 when both are sent" do
    get ping_path(@monitor.ping_token, status: 0, s: 1)

    assert_response :success
    assert_equal "success", @monitor.ping_events.order(:received_at).last.kind
    assert_equal "up", @monitor.reload.status
  end

  # Blank/absent/"0" status is the success path, exactly as today.
  test "status=0 and a blank status take the success path unchanged" do
    get ping_path(@monitor.ping_token, status: 0)
    assert_equal "success", @monitor.ping_events.order(:received_at).last.kind

    get ping_path(@monitor.ping_token, status: "")
    assert_equal "success", @monitor.ping_events.order(:received_at).last.kind
    assert_equal "up", @monitor.reload.status
  end

  # A message on a success ping is simply ignored in V1 (§12-E).
  test "a message on a success ping is ignored" do
    get ping_path(@monitor.ping_token, message: "not an error")

    assert_response :success
    event = @monitor.ping_events.order(:received_at).last
    assert_equal "success", event.kind
    assert_nil event.error
  end

  test "the message is truncated server-side to ERROR_MESSAGE_LIMIT" do
    up = monitors(:up)
    get ping_path(up.ping_token, status: 1, message: "e" * (Stablemate::ERROR_MESSAGE_LIMIT + 50))

    assert_response :success
    assert_equal Stablemate::ERROR_MESSAGE_LIMIT, up.ping_events.order(:received_at).last.error.length
  end

  # A failure with no message still records a non-blank error, so the alert is
  # never blank.
  test "a non-zero status without a message records 'exited with status <n>'" do
    up = monitors(:up)
    get ping_path(up.ping_token, status: 137)

    assert_response :success
    assert_equal "exited with status 137", up.ping_events.order(:received_at).last.error
  end

  test "POST with form-encoded status and message behaves like GET" do
    up = monitors(:up)
    post ping_path(up.ping_token), params: { status: "1", message: "boom" }

    assert_response :success
    assert up.reload.down?
    assert_equal "boom", up.ping_events.order(:received_at).last.error
  end

  # Bracket-syntax params (?status[]=1, ?status[a]=b) arrive as Array/Parameters,
  # not String — they must be ignored (success path), never stored as
  # stringified garbage in a failure report.
  test "an Array status is ignored and takes the success path" do
    get ping_path(@monitor.ping_token, status: [ 1 ])

    assert_response :success
    event = @monitor.ping_events.order(:received_at).last
    assert_equal "success", event.kind
    assert_nil event.error
    assert_equal "up", @monitor.reload.status
  end

  test "a Hash status is ignored and takes the success path" do
    get ping_path(@monitor.ping_token, status: { a: 1 })

    assert_response :success
    event = @monitor.ping_events.order(:received_at).last
    assert_equal "success", event.kind
    assert_nil event.error
  end

  test "a non-String message on a failure falls back to 'exited with status <n>'" do
    up = monitors(:up)
    get ping_path(up.ping_token, status: 1, message: [ "x" ])

    assert_response :success
    assert up.reload.down?
    assert_equal "exited with status 1", up.ping_events.order(:received_at).last.error
  end

  # The failure params change nothing about token opacity.
  test "an unknown token with failure params still returns the opaque 404" do
    assert_no_difference -> { PingEvent.count } do
      get ping_path("definitely-not-a-real-token", status: 1, message: "boom")
    end

    assert_response :not_found
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
