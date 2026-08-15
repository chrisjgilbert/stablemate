# frozen_string_literal: true

require "set"

module Stablemate
  module Execution
    # Subscribes to ActiveSupport::Notifications' `perform.active_job` and, on a
    # SUCCESSFUL perform, fires a fire-and-forget check-in for the matching task
    # key. Its mirror is the after_discard path: a TERMINAL failure — unhandled
    # raise, retry_on exhausted, discard_on — reports the error under the same
    # key. Attempts that will be retried report nothing.
    #
    # The task key IS the address (§3.2): it is a name the gem already has, so
    # there is nothing to resolve, fetch, cache or invalidate here — the map
    # handed in at construction is the whole of the routing, and a class missing
    # from it checks in nowhere (§6.3).
    #
    # Backend-agnostic: it keys off the ActiveJob notification, not Solid Queue.
    #
    # Requests are dispatched to a background thread and nothing may propagate into
    # the host job. The check-in credential lives in the Client, not here.
    class Subscriber
      include Logging

      EVENT = "perform.active_job"
      RETRY_EVENT = "enqueue_retry.active_job"
      # Thread-local set of job_ids whose CURRENT attempt did not succeed. The
      # perform.active_job payload records only UNHANDLED exceptions — a failure
      # swallowed by discard_on/retry_on closes its perform event with a clean
      # payload, which would read as a success. Both terminal signals
      # (after_discard) and will-retry signals (enqueue_retry) fire on the job's own
      # thread BEFORE that perform event closes, so a same-thread marker keyed by
      # job_id (inline-adapter nesting safe) is race-free.
      FAILED_ATTEMPTS_KEY = :stablemate_failed_job_ids

      class << self
        # Install ONE Base-level after_discard callback that DELEGATES to whatever
        # subscriber is currently armed — a no-op until one is. Idempotent, and must
        # run EARLY (before the host's job classes load): after_discard_procs is a
        # copy-on-write class_attribute, so a job class that registers its own
        # after_discard snapshots Base's array at that moment, and a hook registered
        # later would never reach it. Delegation also means re-arming a different
        # subscriber never stacks callbacks.
        #
        # On hosts without after_discard this is a silent no-op: error reporting
        # degrades to plain missed-beat detection.
        def install_discard_hook
          # @installing guards RE-ENTRY, not concurrency (§9.6). `defined?` does not
          # force ActiveJob's autoload but `.respond_to?` does, and that load runs
          # the on_load(:active_job) hooks — including the railtie's, which calls
          # this method again while @discard_hook is still nil. Without the flag the
          # inner call installs the hook, the outer call then overwrites
          # @discard_hook and installs a SECOND one, and every terminal failure
          # reports twice. A separate flag rather than an early @discard_hook
          # assignment: assigning it before the capability check would leave it set
          # on a host without after_discard (Rails < 7.1), where remove_discard_hook
          # then raises.
          return if @discard_hook || @installing

          @installing = true
          return unless defined?(::ActiveJob::Base) && ::ActiveJob::Base.respond_to?(:after_discard)
          # Re-check: the invariant is "at most one gem hook in
          # after_discard_procs", not "at most one level of nesting" — a nested
          # call that ran to completion during the line above has already
          # installed it, and this frame's own guard was evaluated before that.
          return if @discard_hook

          @discard_hook = proc { |job, exception| Stablemate.execution_subscriber&.handle_discard(job, exception) }
          ::ActiveJob::Base.after_discard(&@discard_hook)
        ensure
          @installing = false
        end

        # Subclasses that copied after_discard_procs while the hook was installed
        # keep their copy, but it only delegates — with no subscriber armed it stays
        # a no-op.
        def remove_discard_hook
          return unless @discard_hook

          ::ActiveJob::Base.after_discard_procs -= [ @discard_hook ]
          @discard_hook = nil
        end
      end

      # @param class_to_keys [Hash{String=>Array<String>}] job class name -> task
      #   keys. The REPORTABLE map (§6.3): every key in it is one the registrar
      #   also registers, and a job class absent from it never checks in. Boot
      #   builds it with Registrar#reportable_class_to_keys.
      # @param dispatcher    [#call] how a check-in block is executed. The default
      #   is a fire-and-forget background thread: a slow or down Stablemate server
      #   must never block the host's worker. The block never raises — errors are
      #   logged and swallowed inside it.
      def initialize(class_to_keys:, client: nil, config: Stablemate.config,
                     dispatcher: ->(blk) { Thread.new(&blk) })
        @class_to_keys = class_to_keys
        @client = client || Client.new(config)
        @config = config
        @dispatcher = dispatcher
      end

      # The enqueue_retry subscription marks a will-retry attempt so its
      # clean-payload perform close can't success-ping and reset the monitor's
      # overdue clock.
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

      # Arm THIS subscriber for terminal-failure reporting. Re-arming a different
      # subscriber simply re-points the delegation; it can never stack a second
      # callback.
      def subscribe_discards!
        self.class.install_discard_hook
        Stablemate.execution_subscriber = self
        self
      end

      def unsubscribe!
        ActiveSupport::Notifications.unsubscribe(@handle) if @handle
        ActiveSupport::Notifications.unsubscribe(@retry_handle) if @retry_handle
        # The Base-level hook stays installed but delegates to nobody until the next
        # subscribe_discards!.
        Stablemate.execution_subscriber = nil if Stablemate.execution_subscriber.equal?(self)
      end

      # The rescue is load-bearing (§6.5): an exception raised inside a
      # `perform.active_job` subscriber propagates out of the instrumenter and
      # into perform_now, so an error here would FAIL THE HOST'S JOB — the one
      # thing the gem guarantees it can never do. The payload is the host's, and
      # nothing about it is ours to trust.
      def handle_event(event)
        job = event.payload[:job]
        return unless job

        # Consume the failed-attempt marker FIRST, before any config gate — the
        # closing perform event is the cleanup point (it fires last in every mode),
        # and a lingering marker would swallow a later success.
        failed = failed_attempt?(job)
        return unless @config.ping_on_success
        return if failed
        # An UNHANDLED raise records the exception on the payload -> no ping.
        # Failures handled by discard_on/retry_on never appear here — they are
        # exactly what the marker above catches.
        return if event.payload[:exception] || event.payload[:exception_object]

        keys = resolve_keys(job.class.name)
        return if keys.empty?

        warn_if_ambiguous(job.class.name, keys)
        keys.each { |key| ping(key) }
      rescue StandardError => e
        log_warn("perform handling failed: #{e.class}: #{e.message}")
      end

      # The attempt failed but the job will run again, so this cycle is neither a
      # success (no ping — it must not advance the monitor's clock) nor a terminal
      # failure (no report).
      def handle_retry(event)
        job = event.payload[:job]
        mark_failed_attempt(job) if job
      rescue StandardError => e
        log_warn("retry marking failed: #{e.class}: #{e.message}")
      end

      # One TERMINAL job failure, delivered by the after_discard callback.
      #
      # The outer rescue is load-bearing, not belt-and-braces: ActiveJob's
      # run_after_discard_procs RE-RAISES callback exceptions into the host worker,
      # so nothing — not even a hostile exception#message — may escape.
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

        # CONSUMES the marker (Set#delete? is nil when absent) — the perform event
        # closes last, so this doubles as cleanup.
        def failed_attempt?(job)
          !!Thread.current[FAILED_ATTEMPTS_KEY]&.delete?(job.job_id)
        end

        # Truncated AT BUILD TIME so a multi-megabyte message is neither copied
        # around the host thread nor retained by the dispatch closure (the client
        # truncates again — defence in depth).
        #
        # rescue Exception: a hostile #message can raise a NON-StandardError
        # (ScriptError family), and ActiveJob RE-RAISES after_discard callback
        # exceptions into the host worker — even those must not escape.
        def failure_message(exception)
          "#{exception.class}: #{exception.message}"[0, Client::ERROR_MESSAGE_LIMIT]
        rescue Exception # rubocop:disable Lint/RescueException
          exception.class.to_s
        end

        # The map is the complete answer (§6.3). There is deliberately no fallback
        # to the job class name: with no server-supplied address cache to ask "does
        # a monitor exist with this name?", such a fallback would check in for every
        # job class in the host app.
        def resolve_keys(class_name)
          @class_to_keys[class_name] || []
        end

        def warn_if_ambiguous(class_name, keys)
          return if keys.size <= 1

          log_warn("#{class_name} maps to multiple recurring tasks (#{keys.join(', ')}); pinging all.")
        end

        def ping(key)
          dispatch(key, label: "ping") { |k| @client.ping(k) }
        end

        def report_failure(key, message)
          dispatch(key, label: "failure report") { |k| @client.report_failure(k, message: message) }
        end

        # The label keeps dropped pings and dropped failure reports distinguishable
        # in the host's logs.
        def dispatch(key, label:, &request)
          @dispatcher.call(-> { deliver(key, label, &request) })
        rescue StandardError => e
          # Guards the dispatch itself (e.g. Thread.new raising under thread
          # exhaustion) — nothing may propagate into the host job.
          log_warn("#{label} dispatch failed: #{e.class}: #{e.message}")
        end

        # The real Client swallows its own errors, but an injected/wrapping client is
        # public API and may raise; uncaught, that would escape the background thread
        # — spewing via report_on_exception and, under a host's
        # Thread.abort_on_exception, killing the worker.
        #
        # The client's return value is deliberately ignored: every state it can
        # report is either fine or already logged there (§6.5), and none of them is
        # actionable from a job's thread.
        def deliver(key, label)
          yield(key)
        rescue StandardError => e
          log_warn("#{label} thread failed: #{e.class}: #{e.message}")
        end
    end
  end
end
