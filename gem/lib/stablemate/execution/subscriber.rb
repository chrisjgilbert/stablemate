# frozen_string_literal: true

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

      # Attach to ActiveSupport::Notifications. Returns the subscriber handle.
      def subscribe!
        require "active_support/notifications"
        @handle = ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          handle_event(event)
        end
        self
      end

      # Register ONE global ActiveJob::Base.after_discard callback (Rails ≥ 7.1
      # public API, inherited by every job class) routing terminal failures —
      # unhandled raise, retry_on exhausted, discard_on — to handle_discard.
      # On older hosts (no after_discard) this is a silent no-op: error
      # reporting degrades to plain missed-beat detection. Returns self so the
      # railtie can chain it after subscribe!.
      def subscribe_discards!
        return self unless defined?(::ActiveJob::Base) && ::ActiveJob::Base.respond_to?(:after_discard)

        subscriber = self
        ::ActiveJob::Base.after_discard { |job, exception| subscriber.handle_discard(job, exception) }
        self
      end

      def unsubscribe!
        ActiveSupport::Notifications.unsubscribe(@handle) if @handle
      end

      # Process one perform event. Public so tests can drive it directly without
      # the notification plumbing.
      def handle_event(event)
        return unless @config.ping_on_success
        # A raised perform records an exception on the event payload -> no ping.
        return if event.payload[:exception] || event.payload[:exception_object]

        job = event.payload[:job]
        return unless job

        keys = resolve_keys(job.class.name)
        return if keys.empty?

        warn_if_ambiguous(job.class.name, keys)
        keys.each { |key| ping(key) }
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
        return unless @config.ping_on_failure

        keys = resolve_keys(job.class.name)
        return if keys.empty?

        warn_if_ambiguous(job.class.name, keys)
        message = "#{exception.class}: #{exception.message}"
        keys.each { |key| report_failure(key, message) }
      rescue StandardError => e
        log_warn("failure report skipped: #{e.class}: #{e.message}")
      end

      private
        attr_reader :config

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
          dispatch(key) { |url| @client.ping(url) }
        end

        def report_failure(key, message)
          dispatch(key) { |url| @client.report_failure(url, message: message) }
        end

        # Resolve the key's URL and hand the request (a block taking the URL and
        # returning the client's :ok/:stale/:error) to the dispatcher.
        def dispatch(key, &request)
          url = url_for(key)
          return unless url

          @dispatcher.call(-> { deliver(url, &request) })
        rescue StandardError => e
          # Guards the dispatch itself (e.g. Thread.new raising under thread
          # exhaustion) — nothing may propagate into the host job.
          log_warn("ping dispatch failed: #{e.class}: #{e.message}")
        end

        # The dispatched block. The real Client swallows its own errors, but an
        # injected/wrapping client is public API and may raise; uncaught, that
        # would escape the background thread — spewing via report_on_exception
        # and, under a host's Thread.abort_on_exception, killing the worker.
        def deliver(url)
          # A :stale result means the cached URL was rejected (token rotated) — kick
          # a bounded re-sync so the fresh URL is picked up, instead of silently
          # pinging a dead URL until the next boot/manual sync.
          trigger_resync if yield(url) == :stale
        rescue StandardError => e
          log_warn("ping thread failed: #{e.class}: #{e.message}")
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
