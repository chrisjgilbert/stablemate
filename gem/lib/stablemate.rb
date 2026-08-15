# frozen_string_literal: true

require "logger"

require_relative "stablemate/version"
require_relative "stablemate/configuration"
require_relative "stablemate/logging"
require_relative "stablemate/client"
require_relative "stablemate/declaration"
require_relative "stablemate/overrides"
require_relative "stablemate/registrars/registrar"
require_relative "stablemate/registrars/declared_monitors"
require_relative "stablemate/registrars/solid_queue_recurring"
require_relative "stablemate/registration"
require_relative "stablemate/commands/install"
require_relative "stablemate/commands/sync"
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

    # Test helper. There is no shared state left to reset beyond these two: the
    # ping-URL cache — this gem's only state shared between threads, an immutable
    # snapshot swapped under a lock — went with the addresses it held (§3.2).
    def reset!
      @config = Configuration.new
      @execution_subscriber = nil
    end

    # Rails.logger before the stderr default: the gem's log lines are the only
    # signal a misconfigured deploy produces now that boot no longer syncs, and
    # stderr is the channel the original boot-sync warning went to unseen — it
    # bypasses the host's formatter, level and tags. Resolved per call, since
    # Rails.logger is still nil while the initializers are running.
    def logger
      config.logger || rails_logger || default_logger
    end

    # Registration, programmatically — the only thing that registers anything now
    # that boot doesn't (§6.5). A sync FAILURE never raises: it logs and answers
    # nil. A CONFIG error does, on purpose, and fails the whole run before any
    # request is made (§3.1). Nothing on the boot path calls this, so neither
    # outcome can keep the host app from starting.
    #
    # `bin/rails stablemate:sync` does NOT come through here: the command owns
    # the environment guard, the report and the exit status (§6.1), which is
    # Commands::Sync's whole job.
    def sync!(prune: false)
      Registration.new.sync!(prune:)
    end

    private
      def rails_logger
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:logger)

        ::Rails.logger
      end

      def default_logger
        @default_logger ||= Logger.new($stderr).tap { |l| l.progname = "stablemate" }
      end
  end
end

# A plain-Ruby host just requires the objects above directly.
require_relative "stablemate/railtie" if defined?(::Rails::Railtie)
