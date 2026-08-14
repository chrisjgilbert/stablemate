# frozen_string_literal: true

require_relative "../test_helper"

class SubscriberTest < StablemateTest
  # A stand-in for an ActiveJob instance — #class.name and #job_id are read.
  # job_id is unique per fake (like the real thing), so failed-attempt markers
  # can never bleed between unrelated fakes/tests.
  #
  # The fake is a real INSTANCE of the anonymous class, so #class answers
  # honestly. (It used to be an Object with #class patched to return the class —
  # which lied to anything that asked: an is_a?, an error message, a debugger.)
  # Naming the anonymous class is the one piece of reflection left, and there is
  # no other way to give an anonymous Ruby class an arbitrary .name — which is
  # exactly what the subscriber keys on.
  def job(class_name)
    klass = Class.new do
      def job_id = @job_id ||= "fake-job-#{object_id}"
    end
    klass.define_singleton_method(:name) { class_name }
    klass.new
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

  def subscriber(class_to_keys:, client:, dispatcher: SYNC_DISPATCHER)
    Stablemate::Execution::Subscriber.new(
      class_to_keys:, client:, config: Stablemate.config, dispatcher:
    )
  end

  # Scenario 17 — a successful perform of a mapped job checks in under the
  # task's own key. The key IS the address now (§3.2): nothing is resolved,
  # fetched or cached on the way there.
  def test_successful_perform_checks_in_under_the_mapped_task_key
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] }, client:)

    sub.handle_event(event("DailyDigestJob"))

    assert_equal [ "daily_digest" ], client.pinged
  end

  # Scenario 18 — a raising perform fires NO ping.
  def test_raising_perform_does_not_ping
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] }, client:)

    sub.handle_event(event("DailyDigestJob", exception: RuntimeError.new("nope")))

    assert_empty client.pinged
  end

  # Scenario 19 — ping delivery swallows errors; nothing propagates into the
  # host job. The synchronous dispatcher makes this a direct assertion: a
  # raising client must not raise out of handle_event.
  def test_ping_errors_are_swallowed
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)

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
    logger = Stablemate::RecordingLogger.new
    Stablemate.config.logger = logger

    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = Stablemate::Execution::Subscriber.new(
      class_to_keys: { "J" => [ "k" ] }, client:, config: Stablemate.config
    )

    sub.handle_event(event("J"))

    assert_match(/ping thread failed/, logger.next_warning)
    assert_empty client.pinged
  end

  # §6.5 — handle_event was the only public handler without a rescue, and an
  # exception raised in a `perform.active_job` subscriber propagates back out of
  # ActiveSupport::Notifications into perform_now: the gem would fail the HOST's
  # job. The payload is the host's, not ours, so nothing about it may be trusted.
  def test_handle_event_swallows_an_exception_from_a_hostile_payload
    logger = Stablemate::RecordingLogger.new
    Stablemate.config.logger = logger
    hostile = Object.new
    def hostile.[](_key) = raise(IOError, "hostile payload")

    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client: Stablemate::FakeClient.new)

    begin
      sub.handle_event(Event.new(hostile))
    rescue StandardError
      flunk("an exception propagated out of handle_event into the host job")
    end
    assert_match(/perform handling failed/, logger.next_warning)
  end

  # The real Client#ping swallows everything too (no exception escapes) — a
  # transport failure is transient, never raised.
  def test_real_client_ping_swallows_errors
    # The address is derived from config.endpoint now, so the endpoint — not the
    # argument — is what has to be unroutable: left at its default this test would
    # send a live request to the production server.
    Stablemate.config.endpoint = "http://127.0.0.1:1"
    client = Stablemate::Client.new

    assert_equal :transient, client.ping("daily_digest")
  end

  # Scenario 20 — a perform with no matching task key fires no ping. THE
  # invariant of §6.3: the reportable map is the complete answer now, so an
  # unlisted job class checks in nowhere. It used to be enforced by the absence
  # of a cached address — the thing this redesign deletes — via a class-name
  # fallback that would otherwise report for every job class in the host app.
  def test_unmapped_perform_does_not_ping
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] }, client:)

    sub.handle_event(event("SomeOtherJob"))

    assert_empty client.pinged
  end

  # The discard arm of the same invariant: the fallback had a second call site,
  # so deleting it in one place would leave terminal failures reporting for
  # every job class in the host app.
  def test_handle_discard_of_an_unmapped_class_reports_nothing
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] }, client:)

    sub.handle_discard(job("CleanupJob"), IOError.new("disk full"))

    assert_empty client.reported
  end

  # Scenario 26 — two tasks sharing a job class -> both pinged + a warning logged.
  def test_shared_class_pings_all_and_warns
    client = Stablemate::FakeClient.new
    logger = Stablemate::RecordingLogger.new
    Stablemate.config.logger = logger

    sub = subscriber(class_to_keys: { "ReportJob" => %w[morning_report evening_report] }, client:)

    sub.handle_event(event("ReportJob"))

    assert_equal %w[morning_report evening_report].sort, client.pinged.sort
    assert(logger.warnings.any? { |m| m.include?("ReportJob") && m.include?("multiple") })
  end

  # Scenario 28 (wiring) — the subscriber fires via a REAL
  # ActiveSupport::Notifications "perform.active_job" event, the same event any
  # ActiveJob backend (test/async/inline, not just Solid Queue) instruments.
  # Its vehicle used to be the class-name fallback (deleted with §6.3); a mapped
  # class exercises the same subscription.
  def test_subscribes_to_real_active_job_notifications
    require "active_support"
    require "active_support/notifications"

    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "CleanupJob" => [ "cleanup" ] }, client:).subscribe!

    begin
      ActiveSupport::Notifications.instrument("perform.active_job", job: job("CleanupJob")) { :ok }
    ensure
      sub.unsubscribe!
    end

    assert_equal [ "cleanup" ], client.pinged
  end

  # The production default (no injected dispatcher) is fire-and-forget: the ping
  # runs on a background thread, not inline in the worker. Pins decision #4.
  # FakeClient#ping_threads is a Queue, so #pop blocks until the ping lands —
  # deterministic, no polling. (It used to be a #ping patched onto the instance,
  # which meant the double under test was not the double the other tests use.)
  def test_default_dispatcher_pings_on_a_background_thread
    require "timeout"
    client = Stablemate::FakeClient.new

    sub = Stablemate::Execution::Subscriber.new(
      class_to_keys: { "J" => [ "k" ] }, client:, config: Stablemate.config
    )
    sub.handle_event(event("J"))

    pinging_thread = Timeout.timeout(5) { client.ping_threads.pop }
    assert_equal [ "k" ], client.pinged
    refute_equal Thread.current, pinging_thread, "ping ran inline instead of on a background thread"
  end

  # Last line of defense: the logger is pluggable public API, so even a logger
  # whose #warn raises (closed IO, broken sink) must not let an exception
  # escape into the host job — the rescues that call log_warn are exactly the
  # paths that exist to guarantee that.
  def test_a_raising_logger_cannot_escape_into_the_host_job
    Stablemate.config.logger = Stablemate::RaisingLogger.new(IOError.new("closed stream"))
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(
      class_to_keys: { "ReportJob" => %w[a b] }, # ambiguous -> warn on the in-job path too
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
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)

    threads = 20.times.map { Thread.new { sub.handle_event(event("J")) } }
    threads.each(&:join)

    assert_equal 20, client.pinged.size
    assert_equal [ "k" ], client.pinged.uniq
  end

  # ping_on_success = false suppresses pings entirely.
  def test_ping_on_success_false_suppresses_pings
    Stablemate.config.ping_on_success = false
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    sub.handle_event(event("J"))
    assert_empty client.pinged
  end

  # --- handle_discard (spec §3.2): a TERMINAL job failure reports status=1 +
  # "ExceptionClass: message" under the same task key, with the same key
  # resolution, dispatch and swallow discipline as handle_event. ---

  def test_handle_discard_reports_the_exception_under_the_mapped_key
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "DailyDigestJob" => [ "daily_digest" ] }, client:)

    sub.handle_discard(job("DailyDigestJob"), RuntimeError.new("it broke"))

    assert_equal [ { key: "daily_digest", message: "RuntimeError: it broke" } ], client.reported
    assert_empty client.pinged
  end

  # Ambiguity: same rule as handle_event — report all mapped tasks and warn.
  def test_handle_discard_shared_class_reports_all_and_warns
    client = Stablemate::FakeClient.new
    logger = Stablemate::RecordingLogger.new
    Stablemate.config.logger = logger

    sub = subscriber(class_to_keys: { "ReportJob" => %w[morning_report evening_report] }, client:)

    sub.handle_discard(job("ReportJob"), RuntimeError.new("boom"))

    assert_equal %w[morning_report evening_report].sort, client.reported.map { |r| r[:key] }.sort
    assert(logger.warnings.any? { |m| m.include?("ReportJob") && m.include?("multiple") })
  end

  def test_ping_on_failure_false_suppresses_failure_reports
    Stablemate.config.ping_on_failure = false
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)

    sub.handle_discard(job("J"), RuntimeError.new("boom"))

    assert_empty client.reported
  end

  # NOTHING may escape handle_discard: ActiveJob's run_after_discard_procs
  # RE-RAISES exceptions from after_discard callbacks into the host worker, so
  # the swallow contract here is even more load-bearing than on handle_event.
  def test_handle_discard_swallows_client_errors
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)

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
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    hostile = RuntimeError.new("boom")
    hostile.define_singleton_method(:message) { raise IOError, "broken message" }

    begin
      sub.handle_discard(job("J"), hostile)
    rescue StandardError
      flunk("an error from exception#message propagated out of handle_discard")
    end
    assert_equal [ { key: "k", message: "RuntimeError" } ], client.reported
  end

  # A hostile #message may raise a NON-StandardError (ScriptError family) —
  # ActiveJob RE-RAISES after_discard callback exceptions into the host worker,
  # so even those must be caught at the message-build seam.
  def test_handle_discard_survives_a_message_raising_a_non_standard_error
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    hostile = RuntimeError.new("boom")
    hostile.define_singleton_method(:message) { raise NotImplementedError, "nope" }

    begin
      sub.handle_discard(job("J"), hostile)
    rescue Exception # rubocop:disable Lint/RescueException -- the escape itself is the failure under test
      flunk("a non-StandardError from exception#message propagated out of handle_discard")
    end
    assert_equal [ { key: "k", message: "RuntimeError" } ], client.reported
  end

  # Truncation happens AT BUILD TIME (host thread), so a multi-megabyte message
  # is never copied around full-size or retained by the dispatch closure — the
  # client's own truncation stays as defence in depth.
  def test_handle_discard_truncates_the_message_at_build_time
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    limit = Stablemate::Client::ERROR_MESSAGE_LIMIT

    sub.handle_discard(job("J"), RuntimeError.new("e" * (limit * 2)))

    message = client.reported.first[:message]
    assert_equal limit, message.length
    assert message.start_with?("RuntimeError: eee")
  end

  # A failure-report drop must be greppable as such, not disguised as a "ping"
  # failure.
  def test_failure_report_drops_log_with_their_own_label
    logger = Stablemate::RecordingLogger.new
    Stablemate.config.logger = logger
    client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)

    sub.handle_discard(job("J"), RuntimeError.new("boom"))

    message = logger.next_warning
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
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    j = job("J")

    sub.handle_discard(j, RuntimeError.new("boom")) # discard_on: payload will carry NO exception
    sub.handle_event(success_event(j))              # the same attempt's perform event closing

    assert_equal 1, client.reported.size
    assert_empty client.pinged
  end

  def test_a_will_retry_attempt_neither_reports_nor_pings
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
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
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    j = job("J")

    sub.handle_retry(success_event(j))
    sub.handle_event(success_event(j)) # failed attempt: no ping
    sub.handle_event(success_event(j)) # retried attempt succeeds: pings

    assert_equal [ "k" ], client.pinged
  end

  # Cleanup must not depend on config gates: the marker is consumed even while
  # ping_on_success is off, so it can't linger and swallow a later real success.
  def test_the_marker_is_consumed_even_when_ping_on_success_is_off
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    j = job("J")

    Stablemate.config.ping_on_success = false
    sub.handle_retry(success_event(j))
    sub.handle_event(success_event(j)) # gate off, but the marker must still be consumed

    Stablemate.config.ping_on_success = true
    sub.handle_event(success_event(j)) # a real success later must ping

    assert_equal [ "k" ], client.pinged
  end

  # ping_on_failure = false disables REPORTING, not correctness: a discarded
  # job is still not a success, so it must not success-ping either.
  def test_a_discarded_job_does_not_success_ping_even_with_ping_on_failure_off
    Stablemate.config.ping_on_failure = false
    client = Stablemate::FakeClient.new
    sub = subscriber(class_to_keys: { "J" => [ "k" ] }, client:)
    j = job("J")

    sub.handle_discard(j, RuntimeError.new("boom"))
    sub.handle_event(success_event(j))

    assert_empty client.reported
    assert_empty client.pinged
  end
end
