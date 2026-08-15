# frozen_string_literal: true

require_relative "registrar"
require_relative "../declaration"

module Stablemate
  module Registrars
    # `c.monitors` — work that is not a Rails job (a shell cron, a backup script),
    # declared in the same initializer as everything else so it registers through
    # the same command (§3.1):
    #
    #   c.monitors = { "pg_backup" => { interval: 86_400, grace: 7_200 } }
    #
    # A registrar rather than a hash Registration folds in by hand, because the
    # translation is the whole job: the server's entry struct reads
    # registration_key / name / expected_interval_seconds / grace_period_seconds,
    # and `{ interval:, grace: }` matches none of those and carries no key at all.
    # Untranslated, every entry is silently dropped — sync reports success and
    # every check-in against it 404s forever (§6.3).
    #
    # This is NOT the registrar the reportable map is built from, and it never can
    # be: see #class_to_keys.
    class DeclaredMonitors < Registrar
      def initialize(config: Stablemate.config)
        @config = config
      end

      def tuples
        config.monitors.to_h.map { |key, entry| tuple(key.to_s, entry) }
      end

      # Empty, structurally — §6.3's hard rule made a property of the class rather
      # than something a future reader has to remember. These keys have no job
      # class by definition and are arbitrary user strings, so a key that happened
      # to equal a host job class name would bind that class to the shell script's
      # monitor: an unrelated Rails job would advance it, and the monitor would
      # read green while the backup had been failing.
      def class_to_keys
        {}
      end

      # §6.1 — a c.monitors key is as declared as a recurring.yml task, so a
      # PRUNE=1 run sends it too. Every entry here either registers or fails the
      # whole run (#missing_interval!), so there is no before-the-skips/after
      # distinction to make: the keys ARE the declaration.
      def declared_keys
        config.monitors.to_h.keys.map(&:to_s)
      end

      private
        attr_reader :config

        def tuple(key, entry)
          declaration = Declaration.new(entry, source: "c.monitors[#{key.inspect}]")
          interval = declaration.interval || missing_interval!(key)

          # No `schedule:` — §6.3: an entry declared with a bare interval has no
          # schedule and sends none. The server's column means "the string the
          # interval was derived from", never a promise, so inventing one for a
          # shell script would make it a lie.
          { registration_key: key, name: key,
            expected_interval_seconds: interval,
            grace_period_seconds: declaration.grace_for(interval) }
        end

        # An entry with no interval cannot be registered at all, and skipping it
        # would be the silent drop this class exists to stop: the work checks in
        # against a monitor that was never created.
        def missing_interval!(key)
          raise ConfigurationError,
                "c.monitors[#{key.inspect}] has no interval: — declare how often the work runs, in " \
                "seconds, e.g. { interval: 86_400 }. Without it there is nothing to register and " \
                "every check-in would be refused."
        end
    end
  end
end
