# frozen_string_literal: true

require_relative "../test_helper"

class SubscriberTest < StablemateTest
  # A stand-in for an ActiveJob instance — #class.name and #job_id are read.
  # job_id is unique per fake (like the real thing), so failed-attempt markers
  # can never bleed between unrelated fakes/tests.
  def job(class_name)
    klass = Class.new { define_singleton_method(:name) { class_name } }
    Object.new.tap do |o|
      o.define_singleton_method(:class) { klass }
      o.define_singleton_method(:job_id) { "fake-job-#{object_id}" }
    end
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

  # The same swallow contract on the REAL async path: with the default
  # Thread.new dispatcher, a raising client must be caught INSIDE the thread
  # and logged — an escaped exception would spew via report_on_exception and,
  # under a host's Thread.abort_on_exception = true, kill the worker process.
  def test_raising_client_on_the_default_dispatcher_is_swallowed_and_logged
    require "timeout"
    logged = Queue.new
    Stablemate.config.logger = Object.new.tap { |l| l.define_singleton_method(:warn) { |m| logged << m } }

    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = Stablemate::Execution::Subscriber.new(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/x" },
      client:, config: Stablemate.config
    )

    sub.handle_event(event("J"))

    message = Timeout.timeout(5) { logged.pop }
    assert_match(/ping thread failed/, message)
    assert_empty client.pinged
  end

  # The real Client#ping swallows everything too (no exception escapes) — a
  # transport failure is reported as :error, never raised.
  def test_real_client_ping_swallows_errors
    client = Stablemate::Client.new
    # An unroutable URL must not raise; it's a transient :error, not :ok/:stale.
    assert_equal :error, client.ping("http://127.0.0.1:1/ping/none")
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
  # The Queue blocks until the ping lands — deterministic, no polling.
  def test_default_dispatcher_pings_on_a_background_thread
    require "timeout"
    client = Stablemate::FakeClient.new
    pings = Queue.new
    client.define_singleton_method(:ping) do |url|
      super(url).tap { pings << Thread.current }
    end

    sub = Stablemate::Execution::Subscriber.new(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:, config: Stablemate.config
    )
    sub.handle_event(event("J"))

    pinging_thread = Timeout.timeout(5) { pings.pop }
    assert_equal [ "https://sm.test/ping/k" ], client.pinged
    refute_equal Thread.current, pinging_thread, "ping ran inline instead of on a background thread"
  end

  # Last line of defense: the logger is pluggable public API, so even a logger
  # whose #warn raises (closed IO, broken sink) must not let an exception
  # escape into the host job — the rescues that call log_warn are exactly the
  # paths that exist to guarantee that.
  def test_a_raising_logger_cannot_escape_into_the_host_job
    Stablemate.config.logger = Object.new.tap do |l|
      l.define_singleton_method(:warn) { |_m| raise IOError, "closed stream" }
    end
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(
      class_to_keys: { "ReportJob" => %w[a b] }, # ambiguous -> warn on the in-job path too
      ping_urls: { "a" => "u", "b" => "v" },
      client:
    )

    begin
      sub.handle_event(event("ReportJob"))
    rescue StandardError
      flunk("a raising logger propagated out of the subscriber")
    end
    assert_empty client.pinged
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

  # WU-8 (M3) — a :stale ping (rotated token) triggers a bounded re-sync so the
  # fresh URL is picked up rather than silently pinging a dead URL until reboot.
  def resync_subscriber(client:, resync:, resync_interval: 60)
    Stablemate::Execution::Subscriber.new(
      class_to_keys: { "J" => [ "k" ] }, ping_urls: { "k" => "u" },
      client:, config: Stablemate.config, dispatcher: SYNC_DISPATCHER,
      resync:, resync_interval:
    )
  end

  def test_stale_ping_triggers_a_resync
    resyncs = 0
    sub = resync_subscriber(client: Stablemate::FakeClient.new(ping_status: :stale), resync: -> { resyncs += 1 })
    sub.handle_event(event("J"))
    assert_equal 1, resyncs
  end

  def test_ok_ping_does_not_resync
    resyncs = 0
    sub = resync_subscriber(client: Stablemate::FakeClient.new(ping_status: :ok), resync: -> { resyncs += 1 })
    sub.handle_event(event("J"))
    assert_equal 0, resyncs
  end

  def test_bursty_stale_pings_collapse_to_one_resync_within_the_interval
    resyncs = 0
    sub = resync_subscriber(
      client: Stablemate::FakeClient.new(ping_status: :stale),
      resync: -> { resyncs += 1 }, resync_interval: 3600
    )
    3.times { sub.handle_event(event("J")) }
    assert_equal 1, resyncs
  end

  # --- handle_discard (spec §3.2): a TERMINAL job failure reports status=1 +
  # "ExceptionClass: message" to the same ping URL, with the same key
  # resolution, dispatch and swallow discipline as handle_event. ---

  def test_handle_discard_reports_the_exception_to_the_mapped_url
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] },
      ping_urls: { "daily_digest" => "https://sm.test/ping/abc" },
      client:
    )

    sub.handle_discard(job("DailyDigestJob"), RuntimeError.new("it broke"))

    assert_equal [ { url: "https://sm.test/ping/abc", message: "RuntimeError: it broke" } ], client.reported
    assert_empty client.pinged
  end

  # Manual fallback — same rule as handle_event: a monitor whose
  # registration_key IS the job class name still gets the failure report.
  def test_handle_discard_manual_fallback_by_job_class_name
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: {},
      ping_urls: { "CleanupJob" => "https://sm.test/ping/cleanup" },
      client:
    )

    sub.handle_discard(job("CleanupJob"), IOError.new("disk full"))

    assert_equal [ { url: "https://sm.test/ping/cleanup", message: "IOError: disk full" } ], client.reported
  end

  def test_handle_discard_with_no_matching_key_reports_nothing
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] },
      ping_urls: { "daily_digest" => "u" },
      client:
    )

    sub.handle_discard(job("SomeOtherJob"), RuntimeError.new("nope"))

    assert_empty client.reported
  end

  # Ambiguity: same rule as handle_event — report all mapped tasks and warn.
  def test_handle_discard_shared_class_reports_all_and_warns
    client = Stablemate::FakeClient.new
    logged = []
    Stablemate.config.logger = Object.new.tap { |l| l.define_singleton_method(:warn) { |m| logged << m } }

    sub = subscriber(
      class_to_keys: { "ReportJob" => %w[morning_report evening_report] },
      ping_urls: { "morning_report" => "https://sm.test/ping/m", "evening_report" => "https://sm.test/ping/e" },
      client:
    )

    sub.handle_discard(job("ReportJob"), RuntimeError.new("boom"))

    assert_equal %w[https://sm.test/ping/m https://sm.test/ping/e].sort, client.reported.map { |r| r[:url] }.sort
    assert(logged.any? { |m| m.include?("ReportJob") && m.include?("multiple") })
  end

  def test_ping_on_failure_false_suppresses_failure_reports
    Stablemate.config.ping_on_failure = false
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "u" },
      client:
    )

    sub.handle_discard(job("J"), RuntimeError.new("boom"))

    assert_empty client.reported
  end

  # NOTHING may escape handle_discard: ActiveJob's run_after_discard_procs
  # RE-RAISES exceptions from after_discard callbacks into the host worker, so
  # the swallow contract here is even more load-bearing than on handle_event.
  def test_handle_discard_swallows_client_errors
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/x" },
      client:
    )

    begin
      sub.handle_discard(job("J"), RuntimeError.new("boom"))
    rescue StandardError
      flunk("a client error propagated out of handle_discard")
    end
    assert_empty client.reported
  end

  # The message-building step is untrusted (a host's exception subclass may
  # override #message with something that raises) — nothing escapes, and the
  # report still goes out with the class name alone rather than being dropped.
  def test_handle_discard_reports_the_class_alone_when_message_raises
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "u" },
      client:
    )
    hostile = RuntimeError.new("boom")
    hostile.define_singleton_method(:message) { raise IOError, "broken message" }

    begin
      sub.handle_discard(job("J"), hostile)
    rescue StandardError
      flunk("an error from exception#message propagated out of handle_discard")
    end
    assert_equal [ { url: "u", message: "RuntimeError" } ], client.reported
  end

  # A hostile #message may raise a NON-StandardError (ScriptError family) —
  # ActiveJob RE-RAISES after_discard callback exceptions into the host worker,
  # so even those must be caught at the message-build seam.
  def test_handle_discard_survives_a_message_raising_a_non_standard_error
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "u" },
      client:
    )
    hostile = RuntimeError.new("boom")
    hostile.define_singleton_method(:message) { raise NotImplementedError, "nope" }

    begin
      sub.handle_discard(job("J"), hostile)
    rescue Exception # rubocop:disable Lint/RescueException -- the escape itself is the failure under test
      flunk("a non-StandardError from exception#message propagated out of handle_discard")
    end
    assert_equal [ { url: "u", message: "RuntimeError" } ], client.reported
  end

  # Truncation happens AT BUILD TIME (host thread), so a multi-megabyte message
  # is never copied around full-size or retained by the dispatch closure — the
  # client's own truncation stays as defence in depth.
  def test_handle_discard_truncates_the_message_at_build_time
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "u" },
      client:
    )
    limit = Stablemate::Client::ERROR_MESSAGE_LIMIT

    sub.handle_discard(job("J"), RuntimeError.new("e" * (limit * 2)))

    message = client.reported.first[:message]
    assert_equal limit, message.length
    assert message.start_with?("RuntimeError: eee")
  end

  # A :stale failure report (rotated token) triggers the same bounded re-sync
  # as a stale success ping.
  def test_stale_failure_report_triggers_a_resync
    resyncs = 0
    sub = resync_subscriber(client: Stablemate::FakeClient.new(ping_status: :stale), resync: -> { resyncs += 1 })

    sub.handle_discard(job("J"), RuntimeError.new("boom"))

    assert_equal 1, resyncs
  end

  # A failure-report drop must be greppable as such, not disguised as a "ping"
  # failure.
  def test_failure_report_drops_log_with_their_own_label
    require "timeout"
    logged = Queue.new
    Stablemate.config.logger = Object.new.tap { |l| l.define_singleton_method(:warn) { |m| logged << m } }
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "u" },
      client:
    )

    sub.handle_discard(job("J"), RuntimeError.new("boom"))

    message = Timeout.timeout(5) { logged.pop }
    assert_match(/failure report thread failed/, message)
  end

  # --- The failed-attempt marker: exceptions HANDLED by discard_on/retry_on
  # never reach the perform.active_job payload (exception_object is nil — only
  # unhandled raises record it), so without a marker the closing perform event
  # of a failed attempt would fire a SUCCESS ping: double-firing against the
  # failure report on a discard, and resetting the monitor's overdue clock on
  # every will-be-retried attempt. after_discard and enqueue_retry both fire on
  # the job's own thread BEFORE the perform event closes, so handle_discard /
  # handle_retry mark the job_id and handle_event consumes the mark. ---

  def success_event(j)
    Event.new({ job: j })
  end

  def test_a_discarded_job_does_not_success_ping_on_the_closing_perform_event
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )
    j = job("J")

    sub.handle_discard(j, RuntimeError.new("boom")) # discard_on: payload will carry NO exception
    sub.handle_event(success_event(j))              # the same attempt's perform event closing

    assert_equal 1, client.reported.size
    assert_empty client.pinged
  end

  def test_a_will_retry_attempt_neither_reports_nor_pings
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )
    j = job("J")

    sub.handle_retry(success_event(j)) # enqueue_retry fires before the perform event closes
    sub.handle_event(success_event(j))

    assert_empty client.reported
    assert_empty client.pinged
  end

  # The marker is consumed by the closing perform event, so the NEXT attempt of
  # the same job_id (a retry that succeeds) pings normally.
  def test_the_marker_is_consumed_so_the_next_successful_attempt_pings
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )
    j = job("J")

    sub.handle_retry(success_event(j))
    sub.handle_event(success_event(j)) # failed attempt: no ping
    sub.handle_event(success_event(j)) # retried attempt succeeds: pings

    assert_equal [ "https://sm.test/ping/k" ], client.pinged
  end

  # Cleanup must not depend on config gates: the marker is consumed even while
  # ping_on_success is off, so it can't linger and swallow a later real success.
  def test_the_marker_is_consumed_even_when_ping_on_success_is_off
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )
    j = job("J")

    Stablemate.config.ping_on_success = false
    sub.handle_retry(success_event(j))
    sub.handle_event(success_event(j)) # gate off, but the marker must still be consumed

    Stablemate.config.ping_on_success = true
    sub.handle_event(success_event(j)) # a real success later must ping

    assert_equal [ "https://sm.test/ping/k" ], client.pinged
  end

  # ping_on_failure = false disables REPORTING, not correctness: a discarded
  # job is still not a success, so it must not success-ping either.
  def test_a_discarded_job_does_not_success_ping_even_with_ping_on_failure_off
    Stablemate.config.ping_on_failure = false
    client = Stablemate::FakeClient.new
    sub = subscriber(
      class_to_keys: { "J" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/k" },
      client:
    )
    j = job("J")

    sub.handle_discard(j, RuntimeError.new("boom"))
    sub.handle_event(success_event(j))

    assert_empty client.reported
    assert_empty client.pinged
  end
end
