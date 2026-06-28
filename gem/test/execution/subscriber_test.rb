# frozen_string_literal: true

require_relative "../test_helper"

class SubscriberTest < StablemateTest
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

  def subscriber(class_to_keys:, ping_urls:, client:)
    Stablemate::Execution::Subscriber.new(
      class_to_keys:, ping_urls:, client:, config: Stablemate.config
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
    sub.wait!

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
    sub.wait!

    assert_empty client.pinged
  end

  # Scenario 19 — ping delivery swallows network errors; nothing propagates.
  def test_ping_errors_are_swallowed
    # The real client swallows; here we drive the real Client#ping with a raising
    # transport by pointing at an unroutable URL would be slow, so use FakeClient
    # configured to raise and confirm handle_event still returns without raising.
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/x" },
      client:
    )

    sub.handle_event(event("J"))
    # The ping runs in a thread; joining must not raise into the caller even
    # though the client raises a network error.
    begin
      sub.wait!
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
    sub.wait!

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
    sub.wait!

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
    sub.wait!

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
    sub.wait!

    assert_equal [ "https://sm.test/ping/cleanup" ], client.pinged
  end

  # Thread-safety: many worker threads firing performs concurrently must not tear
  # the @threads bookkeeping or lose pings.
  def test_handles_concurrent_performs_without_losing_pings
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )

    threads = 20.times.map { Thread.new { sub.handle_event(event("J")) } }
    threads.each(&:join)
    sub.wait!

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
    sub.wait!
    assert_empty client.pinged
  end
end
