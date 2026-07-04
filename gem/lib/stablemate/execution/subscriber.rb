# frozen_string_literal: true

module Stablemate
  module Execution
    # Layer 1 (architecture.md §9): subscribe to ActiveSupport::Notifications'
    # `perform.active_job` and, on a SUCCESSFUL perform, fire a fire-and-forget
    # ping to the matching monitor's cached ping URL.
    #
    # Backend-agnostic: it keys off the ActiveJob notification, not Solid Queue,
    # so it works on the test/async/inline adapters too (decision #4 / §4.4).
    #
    # Safety: a raising perform does NOT ping (the notification carries the
    # exception). The ping is dispatched to a background thread and nothing may
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
          url = url_for(key)
          return unless url

          @dispatcher.call(-> { deliver(url) })
        rescue StandardError => e
          # Guards the dispatch itself (e.g. Thread.new raising under thread
          # exhaustion) — nothing may propagate into the host job.
          log_warn("ping dispatch failed: #{e.class}: #{e.message}")
        end

        # The dispatched block. Client#ping swallows its own errors, but an
        # injected/wrapping client is public API and may raise; uncaught, that
        # would escape the background thread — spewing via report_on_exception
        # and, under a host's Thread.abort_on_exception, killing the worker.
        def deliver(url)
          # A :stale result means the cached URL was rejected (token rotated) — kick
          # a bounded re-sync so the fresh URL is picked up, instead of silently
          # pinging a dead URL until the next boot/manual sync.
          trigger_resync if @client.ping(url) == :stale
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
