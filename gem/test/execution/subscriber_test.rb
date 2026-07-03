# frozen_string_literal: true

require_relative "../test_helper"

class SubscriberTest < StablemateTest
  # Runs the ping block synchronously, so by the time handle_event returns the
  # ping has already hit the fake client — deterministic, nothing to wait for.
  SYNC_DISPATCHER = ->(blk) { blk.call }

  # A stand-in for an ActiveJob instance — only #class.name is read.
  def job(class_name)
    klass = Class.new { define_singleton_method(:name) { class_name } }
    Object.new.tap { |o| o.define_singleton_method(:class) { klass } }
  end

  # A stand-in ActiveSupport::Notifications event: only #payload is read.
  Event = Struct.new(:payload)

  # Build an event for a perform of class_name; pass exception: to simulate a
  # raising perform.
  def event(class_name, exception: nil)
    payload = { job: job(class_name) }
    payload[:exception_object] = exception if exception
    Event.new(payload)
  end

  def subscriber(class_to_keys:, ping_urls:, client:, dispatcher: SYNC_DISPATCHER)
    Stablemate::Execution::Subscriber.new(
      class_to_keys:, ping_urls:, client:, config: Stablemate.config, dispatcher:
    )
  end

  # Scenario 17 — a successful perform of a mapped job fires one ping to the
  # correct URL.
  def test_successful_perform_pings_the_mapped_url
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] },
      ping_urls: { "daily_digest" => "https://sm.test/ping/abc" },
      client:
    )

    sub.handle_event(event("DailyDigestJob"))

    assert_equal [ "https://sm.test/ping/abc" ], client.pinged
  end

  # Scenario 18 — a raising perform fires NO ping.
  def test_raising_perform_does_not_ping
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] },
      ping_urls: { "daily_digest" => "u" },
      client:
    )

    sub.handle_event(event("DailyDigestJob", exception: RuntimeError.new("nope")))

    assert_empty client.pinged
  end

  # Scenario 19 — ping delivery swallows errors; nothing propagates into the
  # host job. The synchronous dispatcher makes this a direct assertion: a
  # raising client must not raise out of handle_event.
  def test_ping_errors_are_swallowed
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/x" },
      client:
    )

    begin
      sub.handle_event(event("J"))
    rescue StandardError
      flunk("a network error propagated out of the subscriber")
    end
    assert_empty client.pinged
  end

  # The real Client#ping swallows everything too (no exception escapes).
  def test_real_client_ping_swallows_errors
    client = Stablemate::Client.new
    # An unparseable / unroutable URL must not raise.
    assert_equal false, client.ping("http://127.0.0.1:1/ping/none")
  end

  # Scenario 20 — a perform with no matching task key fires no ping.
  def test_unmapped_perform_does_not_ping
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] },
      ping_urls: { "daily_digest" => "u" },
      client:
    )

    sub.handle_event(event("SomeOtherJob"))

    assert_empty client.pinged
  end

  # Scenario 26 — two tasks sharing a job class -> both pinged + a warning logged.
  def test_shared_class_pings_all_and_warns
    client = Stablemate::FakeClient.new
    logged = []
    Stablemate.config.logger = Object.new.tap { |l| l.define_singleton_method(:warn) { |m| logged << m } }

    sub = subscriber(
      class_to_keys: { "ReportJob" => %w[morning_report evening_report] },
      ping_urls: { "morning_report" => "https://sm.test/ping/m", "evening_report" => "https://sm.test/ping/e" },
      client:
    )

    sub.handle_event(event("ReportJob"))

    assert_equal %w[https://sm.test/ping/m https://sm.test/ping/e].sort, client.pinged.sort
    assert(logged.any? { |m| m.include?("ReportJob") && m.include?("multiple") })
  end

  # Scenario 28 — manual fallback: a monitor whose registration_key IS the job
  # class name (Layer 1 without Layer 2) still pings on a non-Solid-Queue backend.
  def test_manual_fallback_pings_by_job_class_name
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: {}, # no Layer-2 mapping at all
      ping_urls: { "CleanupJob" => "https://sm.test/ping/cleanup" },
      client:
    )

    sub.handle_event(event("CleanupJob"))

    assert_equal [ "https://sm.test/ping/cleanup" ], client.pinged
  end

  # Scenario 28 (wiring) — the subscriber fires via a REAL
  # ActiveSupport::Notifications "perform.active_job" event, the same event any
  # ActiveJob backend (test/async/inline, not just Solid Queue) instruments.
  def test_subscribes_to_real_active_job_notifications
    require "active_support"
    require "active_support/notifications"

    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: {},
      ping_urls: { "CleanupJob" => "https://sm.test/ping/cleanup" },
      client:
    ).subscribe!

    begin
      ActiveSupport::Notifications.instrument("perform.active_job", job: job("CleanupJob")) { :ok }
    ensure
      sub.unsubscribe!
    end

    assert_equal [ "https://sm.test/ping/cleanup" ], client.pinged
  end

  # The production default (no injected dispatcher) is fire-and-forget: the ping
  # runs on a background thread, not inline in the worker. Pins decision #4.
  def test_default_dispatcher_pings_on_a_background_thread
    client = Stablemate::FakeClient.new
    pinging_thread = nil
    client.define_singleton_method(:ping) do |url|
      pinging_thread = Thread.current
      super(url)
    end

    sub = Stablemate::Execution::Subscriber.new(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:, config: Stablemate.config
    )
    sub.handle_event(event("J"))

    deadline = Time.now + 5
    sleep 0.01 while client.pinged.empty? && Time.now < deadline

    assert_equal [ "https://sm.test/ping/k" ], client.pinged
    refute_equal Thread.current, pinging_thread, "ping ran inline instead of on a background thread"
  end

  # Concurrent performs (Solid Queue runs many worker threads) must not lose
  # pings — handle_event holds no shared mutable state.
  def test_handles_concurrent_performs_without_losing_pings
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )

    threads = 20.times.map { Thread.new { sub.handle_event(event("J")) } }
    threads.each(&:join)

    assert_equal 20, client.pinged.size
    assert_equal [ "https://sm.test/ping/k" ], client.pinged.uniq
  end

  # ping_on_success = false suppresses pings entirely.
  def test_ping_on_success_false_suppresses_pings
    Stablemate.config.ping_on_success = false
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "u" },
      client:
    )
    sub.handle_event(event("J"))
    assert_empty client.pinged
  end
end
