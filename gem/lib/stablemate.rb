# frozen_string_literal: true

require "logger"

require_relative "stablemate/version"
require_relative "stablemate/configuration"
require_relative "stablemate/logging"
require_relative "stablemate/client"
require_relative "stablemate/registrars/registrar"
require_relative "stablemate/registrars/solid_queue_recurring"
require_relative "stablemate/registration"
require_relative "stablemate/execution/subscriber"

# Stablemate companion gem: register your Solid Queue recurring jobs as monitors
# and ping them on successful runs — no per-job code.
module Stablemate
  class << self
    # Yields the configuration for the host app's initializer.
    def configure
      yield(config)
      config
    end

    def config
      @config ||= Configuration.new
    end

    # Reset config + the ping-URL cache (test helper).
    def reset!
      @ping_urls = nil
      @config = Configuration.new
    end

    # The task key (or fallback job-class name) -> ping URL map. The map is an
    # immutable snapshot: merge_ping_urls builds a new frozen hash and swaps the
    # reference atomically, so subscriber threads reading mid-re-sync always see
    # a complete map (old or new, never torn). Reads are lock-free and never
    # write (no lazy init) — only merge_ping_urls/reset! assign the ivar.
    def ping_urls
      @ping_urls || EMPTY_PING_URLS
    end

    # Fold new key -> url pairs into the cache (boot / re-sync) by swapping in a
    # fresh frozen snapshot. Writers are serialized: without the lock, two
    # concurrent sync! calls could each merge into the same base snapshot and
    # the second swap would silently drop the first's URLs. Readers never take
    # this lock.
    def merge_ping_urls(pairs)
      MERGE_LOCK.synchronize { @ping_urls = ping_urls.merge(pairs).freeze }
    end

    def logger
      config.logger || default_logger
    end

    # Convenience: run a sync now (used by the rake task; boot wires its own
    # Registration in the railtie so it can reuse the registrar for Layer 1).
    # Never raises.
    def sync!
      Registration.new.sync!
    end

    private
      EMPTY_PING_URLS = {}.freeze
      MERGE_LOCK = Mutex.new

      def default_logger
        @default_logger ||= Logger.new($stderr).tap { |l| l.progname = "stablemate" }
      end
  end
end

# Auto-wire into Rails when present (boot-time sync + execution subscriber +
# rake task). A plain-Ruby host just requires the objects above directly.
require_relative "stablemate/railtie" if defined?(::Rails::Railtie)
