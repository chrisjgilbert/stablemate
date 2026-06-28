# frozen_string_literal: true

require "monitor"

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
    # exception). The ping itself runs in a background thread and swallows every
    # error — it must never block or raise into the job. No API key on this path.
    class Subscriber
      EVENT = "perform.active_job"

      # @param class_to_keys [Hash{String=>Array<String>}] job class name -> task keys.
      # @param ping_urls     [Hash{String=>String}, nil] task key -> ping URL. When
      #   nil (the production default) URLs are resolved LIVE from the shared,
      #   mutex-guarded Stablemate.ping_url_for, so a re-sync that refreshes the
      #   cache is picked up without rebuilding the subscriber. Tests inject an
      #   explicit hash for determinism.
      def initialize(class_to_keys:, ping_urls: nil, client: nil, config: Stablemate.config)
        @class_to_keys = class_to_keys
        @ping_urls = ping_urls
        @client = client || Client.new(config)
        @config = config
        @threads = []
        # perform.active_job fires from many worker threads concurrently; guard the
        # @threads prune+append so there's no torn read / "modified during
        # iteration" under concurrent performs.
        @threads_lock = Monitor.new
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

      # Block until any in-flight ping threads finish (test helper).
      def wait!
        snapshot = @threads_lock.synchronize { @threads.dup }
        snapshot.each(&:join)
      end

      private
        # Resolve a ping URL by key, from the injected hash (tests) or the live
        # shared cache (production).
        def url_for(key)
          @ping_urls ? @ping_urls[key] : Stablemate.ping_url_for(key)
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

          # Fire-and-forget: a background thread, and a belt-and-braces rescue so
          # even a client that raises can never propagate into the host job.
          thread = Thread.new do
            begin
              @client.ping(url)
            rescue StandardError => e
              log_warn("ping thread failed: #{e.class}: #{e.message}")
            end
          end

          # Track only still-running threads so @threads can't grow without bound
          # over a long-lived process (pruned to the in-flight set on each ping).
          # Guarded so concurrent performs don't tear the array. wait! joins
          # whatever is in flight.
          @threads_lock.synchronize do
            @threads.select!(&:alive?)
            @threads << thread
          end
        end

        def log_warn(message)
          (@config.logger || Stablemate.logger).warn("[stablemate] #{message}")
        end
    end
  end
end
