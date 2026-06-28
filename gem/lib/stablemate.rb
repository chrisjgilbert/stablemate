# frozen_string_literal: true

require "logger"
require "monitor"

require_relative "stablemate/version"
require_relative "stablemate/configuration"
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
      ping_urls_lock.synchronize { @ping_urls = {} }
      @config = Configuration.new
    end

    # A snapshot of the task key (or fallback job-class name) -> cached ping URL
    # map. Registration#sync! writes it (cache_ping_urls / merge_ping_urls) while
    # Execution::Subscriber reads it from worker threads, so all access is guarded
    # by a mutex; this returns a copy so callers can't mutate the shared state or
    # see a torn read mid-merge.
    def ping_urls
      ping_urls_lock.synchronize { @ping_urls ||= {}; @ping_urls.dup }
    end

    # Atomically read one ping URL by key (hot path).
    def ping_url_for(key)
      ping_urls_lock.synchronize { (@ping_urls ||= {})[key] }
    end

    # Atomically fold new key -> url pairs into the cache (boot / re-sync).
    def merge_ping_urls(pairs)
      ping_urls_lock.synchronize { (@ping_urls ||= {}).merge!(pairs) }
    end

    def logger
      config.logger || default_logger
    end

    # Convenience: run a sync now (boot / rake task). Never raises.
    def sync!
      Registration.new.sync!
    end

    private
      def ping_urls_lock
        @ping_urls_lock ||= Monitor.new
      end

      def default_logger
        @default_logger ||= Logger.new($stderr).tap { |l| l.progname = "stablemate" }
      end
  end
end

# Auto-wire into Rails when present (boot-time sync + execution subscriber +
# rake task). A plain-Ruby host just requires the objects above directly.
require_relative "stablemate/railtie" if defined?(::Rails::Railtie)
