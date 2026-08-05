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
    def configure
      yield(config)
      config
    end

    def config
      @config ||= Configuration.new
    end

    # The Base-level after_discard hook delegates every discard here; nil (the
    # default) makes that hook a no-op, so assigning this is what ARMS failure
    # reporting.
    attr_accessor :execution_subscriber

    # Test helper. The cache write takes MERGE_LOCK like every other writer — a
    # straggler sync thread's merge must not resurrect the pre-reset snapshot.
    def reset!
      MERGE_LOCK.synchronize { @ping_urls = nil }
      @config = Configuration.new
      @execution_subscriber = nil
    end

    # An immutable snapshot: merge_ping_urls builds a new frozen hash and swaps the
    # reference atomically, so subscriber threads reading mid-re-sync always see a
    # complete map (old or new, never torn). Reads are lock-free and never write.
    def ping_urls
      @ping_urls || EMPTY_PING_URLS
    end

    # Writers are serialized: without the lock, two concurrent sync! calls could
    # each merge into the same base snapshot and the second swap would silently drop
    # the first's URLs. Readers never take this lock.
    def merge_ping_urls(pairs)
      MERGE_LOCK.synchronize { @ping_urls = ping_urls.merge(pairs).freeze }
    end

    def logger
      config.logger || default_logger
    end

    # Used by the rake task; boot wires its own Registration in the railtie so it
    # can reuse the registrar. Never raises.
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

# A plain-Ruby host just requires the objects above directly.
require_relative "stablemate/railtie" if defined?(::Rails::Railtie)
