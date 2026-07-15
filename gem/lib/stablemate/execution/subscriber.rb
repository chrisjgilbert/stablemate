# frozen_string_literal: true

require "set"

module Stablemate
  module Execution
    # Layer 1 (architecture.md §9): subscribe to ActiveSupport::Notifications'
    # `perform.active_job` and, on a SUCCESSFUL perform, fire a fire-and-forget
    # ping to the matching monitor's cached ping URL. Its mirror is the
    # after_discard path (subscribe_discards! / handle_discard): a TERMINAL
    # failure — unhandled raise, retry_on exhausted, discard_on — reports the
    # error (status=1 + message) to the same URL. Attempts that will be
    # retried report nothing.
    #
    # Backend-agnostic: it keys off the ActiveJob notification, not Solid Queue,
    # so it works on the test/async/inline adapters too (decision #4 / §4.4).
    #
    # Safety: a raising perform does NOT ping (the notification carries the
    # exception; if the failure is terminal it becomes a failure report
    # instead). Requests are dispatched to a background thread and nothing may
    # propagate into the host job. No API key on this path.
    class Subscriber
      include Logging

      EVENT = "perform.active_job"
      RETRY_EVENT = "enqueue_retry.active_job"
      # Thread-local set of job_ids whose CURRENT attempt did not succeed.
      # The perform.active_job payload records only UNHANDLED exceptions — a
      # failure swallowed by discard_on/retry_on closes its perform event with
      # a clean payload, which would read as a success. Both terminal signals
      # (after_discard) and will-retry signals (enqueue_retry) fire on the
      # job's own thread BEFORE that perform event closes, so a same-thread
      # marker keyed by job_id (inline-adapter nesting safe) is race-free:
      # handle_discard / handle_retry mark, handle_event consumes.
      FAILED_ATTEMPTS_KEY = :stablemate_failed_job_ids

      class << self
        # Install ONE Base-level after_discard callback (Rails ≥ 7.1) that
        # DELEGATES to whatever subscriber is currently armed
        # (Stablemate.execution_subscriber) — a no-op until one is. Idempotent,
        # and must run EARLY (before the host's job classes load):
        # after_discard_procs is a copy-on-write class_attribute, so a job
        # class that registers its own after_discard (e.g. ApplicationJob
        # wiring an error tracker) snapshots Base's array at that moment — a
        # hook registered later would never reach any such class. Delegation
        # also means re-arming a different subscriber never stacks callbacks,
        # and a stale copy of the hook in some subclass stays harmless.
        # On hosts without after_discard this is a silent no-op: error
        # reporting degrades to plain missed-beat detection.
        def install_discard_hook
          return if @discard_hook
          return unless defined?(::ActiveJob::Base) && ::ActiveJob::Base.respond_to?(:after_discard)

          @discard_hook = proc { |job, exception| Stablemate.execution_subscriber&.handle_discard(job, exception) }
          ::ActiveJob::Base.after_discard(&@discard_hook)
        end

        # Remove the Base-level hook (test/host teardown). Subclasses that
        # copied after_discard_procs while the hook was installed keep their
        # copy, but it only delegates — with no subscriber armed it stays
        # a no-op.
        def remove_discard_hook
          return unless @discard_hook

          ::ActiveJob::Base.after_discard_procs -= [ @discard_hook ]
          @discard_hook = nil
        end
      end

      # @param class_to_keys [Hash{String=>Array<String>}] job class name -> task keys.
      # @param ping_urls     [Hash{String=>String}, nil] task key -> ping URL. When
      #   nil (the production default) URLs are resolved LIVE from the shared
      #   Stablemate.ping_urls snapshot, so a re-sync that refreshes the cache
      #   is picked up without rebuilding the subscriber. Tests inject an explicit
      #   hash for determinism.
      # @param dispatcher    [#call] how a ping block is executed. The default is
      #   a fire-and-forget background thread (decision #4: a slow or down
      #   Stablemate server must never block the host's worker). Tests inject
      #   ->(blk) { blk.call } to run pings synchronously; a host wiring the
      #   subscriber by hand may inject a pooled executor. The block never
      #   raises — errors are logged and swallowed inside it.
      def initialize(class_to_keys:, ping_urls: nil, client: nil, config: Stablemate.config,
                     dispatcher: ->(blk) { Thread.new(&blk) }, resync: nil, resync_interval: 60)
        @class_to_keys = class_to_keys
        @ping_urls = ping_urls
        @client = client || Client.new(config)
        @config = config
        @dispatcher = dispatcher
        # A callable (e.g. -> { Registration#sync! }) invoked when a ping comes back
        # :stale, to refresh the cached ping URLs after a token rotation. Bounded to
        # once per resync_interval seconds so a burst of stale pings can't storm the
        # sync endpoint. Nil (tests / hand-wiring) disables it.
        @resync = resync
        @resync_interval = resync_interval
        @resync_mutex = Mutex.new
        @last_resync_at = nil
      end

      # Attach to ActiveSupport::Notifications: the perform event (success
      # pings + failed-attempt marker consumption) and the enqueue_retry event
      # (marks a will-retry attempt so its clean-payload perform close can't
      # success-ping and reset the monitor's overdue clock). Returns self.
      def subscribe!
        require "active_support/notifications"
        @handle = ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          handle_event(event)
        end
        @retry_handle = ActiveSupport::Notifications.subscribe(RETRY_EVENT) do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          handle_retry(event)
        end
        self
      end

      # Arm THIS subscriber for terminal-failure reporting — unhandled raise,
      # retry_on exhausted, discard_on — by installing the (idempotent,
      # Base-level, delegating) after_discard hook and pointing it here.
      # Re-arming a different subscriber simply re-points the delegation; it
      # can never stack a second callback. Returns self so the railtie can
      # chain it after subscribe!.
      def subscribe_discards!
        self.class.install_discard_hook
        Stablemate.execution_subscriber = self
        self
      end

      def unsubscribe!
        ActiveSupport::Notifications.unsubscribe(@handle) if @handle
        ActiveSupport::Notifications.unsubscribe(@retry_handle) if @retry_handle
        # Disarm failure reporting if this subscriber holds it; the Base-level
        # hook stays installed but delegates to nobody (a no-op) until the next
        # subscribe_discards!.
        Stablemate.execution_subscriber = nil if Stablemate.execution_subscriber.equal?(self)
      end

      # Process one perform event. Public so tests can drive it directly without
      # the notification plumbing.
      def handle_event(event)
        job = event.payload[:job]
        return unless job

        # Consume the failed-attempt marker FIRST, before any config gate —
        # the closing perform event is the cleanup point (it fires last in
        # every mode), and a lingering marker would swallow a later success.
        failed = failed_attempt?(job)
        return unless @config.ping_on_success
        return if failed
        # An UNHANDLED raise records the exception on the payload -> no ping.
        # (Failures handled by discard_on/retry_on never appear here — they
        # are exactly what the marker above catches.)
        return if event.payload[:exception] || event.payload[:exception_object]

        keys = resolve_keys(job.class.name)
        return if keys.empty?

        warn_if_ambiguous(job.class.name, keys)
        keys.each { |key| ping(key) }
      end

      # Process one enqueue_retry event: the attempt failed but the job will
      # run again, so this cycle is neither a success (no ping — it must not
      # advance the monitor's clock) nor a terminal failure (no report).
      def handle_retry(event)
        job = event.payload[:job]
        mark_failed_attempt(job) if job
      rescue StandardError => e
        log_warn("retry marking failed: #{e.class}: #{e.message}")
      end

      # Process one TERMINAL job failure (spec §3.2), delivered by the
      # after_discard callback with (job, exception) in hand. Same key
      # resolution and fire-and-forget dispatch as handle_event; the report is
      # status=1 + "ExceptionClass: message" to the same ping URL, and a :stale
      # result kicks the same bounded re-sync.
      #
      # The outer rescue is load-bearing, not belt-and-braces: ActiveJob's
      # run_after_discard_procs RE-RAISES callback exceptions into the host
      # worker, so nothing — not even a hostile exception#message — may escape.
      def handle_discard(job, exception)
        # Mark before any gate: a discarded attempt is not a success even when
        # reporting is disabled, so the closing perform event must never
        # success-ping it.
        mark_failed_attempt(job)
        return unless @config.ping_on_failure

        keys = resolve_keys(job.class.name)
        return if keys.empty?

        warn_if_ambiguous(job.class.name, keys)
        message = failure_message(exception)
        keys.each { |key| report_failure(key, message) }
      rescue StandardError => e
        log_warn("failure report skipped: #{e.class}: #{e.message}")
      end

      private
        attr_reader :config

        def mark_failed_attempt(job)
          (Thread.current[FAILED_ATTEMPTS_KEY] ||= Set.new) << job.job_id
        end

        # Membership check that CONSUMES the marker (Set#delete? is nil when
        # absent) — the perform event closes last, so this doubles as cleanup.
        def failed_attempt?(job)
          !!Thread.current[FAILED_ATTEMPTS_KEY]&.delete?(job.job_id)
        end

        # Build "ExceptionClass: message", truncated to the shared limit AT
        # BUILD TIME so a multi-megabyte message is neither copied around the
        # host thread nor retained by the dispatch closure (the client
        # truncates again — defence in depth). rescue Exception: a hostile
        # #message can raise a NON-StandardError (ScriptError family), and
        # ActiveJob RE-RAISES after_discard callback exceptions into the host
        # worker — even those must not escape; fall back to the class alone.
        def failure_message(exception)
          "#{exception.class}: #{exception.message}"[0, Client::ERROR_MESSAGE_LIMIT]
        rescue Exception # rubocop:disable Lint/RescueException
          exception.class.to_s
        end

        # Resolve a ping URL by key, from the injected hash (tests) or the live
        # shared cache (production).
        def url_for(key)
          (@ping_urls || Stablemate.ping_urls)[key]
        end

        def resolve_keys(class_name)
          # Layer 2 mapping first; otherwise the manual fallback (decision §4.4):
          # a manually-created monitor whose registration_key IS the job class name.
          keys = @class_to_keys[class_name]
          return keys if keys && !keys.empty?

          url_for(class_name) ? [ class_name ] : []
        end

        def warn_if_ambiguous(class_name, keys)
          return if keys.size <= 1

          log_warn("#{class_name} maps to multiple recurring tasks (#{keys.join(', ')}); pinging all.")
        end

        def ping(key)
          dispatch(key, label: "ping") { |url| @client.ping(url) }
        end

        def report_failure(key, message)
          dispatch(key, label: "failure report") { |url| @client.report_failure(url, message: message) }
        end

        # Resolve the key's URL and hand the request (a block taking the URL and
        # returning the client's :ok/:stale/:error) to the dispatcher. The label
        # keeps dropped pings and dropped failure reports distinguishable in
        # the host's logs.
        def dispatch(key, label:, &request)
          url = url_for(key)
          return unless url

          @dispatcher.call(-> { deliver(url, label, &request) })
        rescue StandardError => e
          # Guards the dispatch itself (e.g. Thread.new raising under thread
          # exhaustion) — nothing may propagate into the host job.
          log_warn("#{label} dispatch failed: #{e.class}: #{e.message}")
        end

        # The dispatched block. The real Client swallows its own errors, but an
        # injected/wrapping client is public API and may raise; uncaught, that
        # would escape the background thread — spewing via report_on_exception
        # and, under a host's Thread.abort_on_exception, killing the worker.
        def deliver(url, label)
          # A :stale result means the cached URL was rejected (token rotated) — kick
          # a bounded re-sync so the fresh URL is picked up, instead of silently
          # pinging a dead URL until the next boot/manual sync.
          trigger_resync if yield(url) == :stale
        rescue StandardError => e
          log_warn("#{label} thread failed: #{e.class}: #{e.message}")
        end

        # Re-sync at most once per @resync_interval seconds (monotonic clock), so a
        # burst of stale pings collapses to one refresh. A resync failure is logged
        # and swallowed — it must never break the ping thread.
        def trigger_resync
          return unless @resync

          @resync_mutex.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return if @last_resync_at && (now - @last_resync_at) < @resync_interval

            @last_resync_at = now
          end
          @resync.call
        rescue StandardError => e
          log_warn("resync after stale ping failed: #{e.class}: #{e.message}")
        end
    end
  end
end
