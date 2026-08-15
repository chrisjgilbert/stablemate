# frozen_string_literal: true

require_relative "overrides"
require_relative "registrars/declared_monitors"
require_relative "registrars/solid_queue_recurring"
require_relative "registration/result"

module Stablemate
  # Build registration tuples from the registrar and POST them to
  # /api/v1/monitors/sync. Idempotent; a sync failure logs a warning and never
  # raises — a CONFIG error does, and fails the whole run (§3.1).
  #
  # Nothing is cached from the response: a check-in addresses itself by task key
  # (§3.2), so there is no per-monitor address to keep, refresh or invalidate.
  class Registration
    include Logging

    # What the server's entry struct reads, and therefore all it is sent. The
    # entries this run plans also carry provenance §6.1's report prints (the
    # pre-override interval), and slicing HERE rather than at the call site means
    # a provenance field added later cannot leak onto the wire by being
    # forgotten.
    WIRE_KEYS = %i[registration_key name expected_interval_seconds grace_period_seconds schedule].freeze

    def initialize(registrar: nil, client: nil, config: Stablemate.config, app: nil)
      @config = config
      @registrar = registrar || Registrars::SolidQueueRecurring.new(config:)
      @declared = Registrars::DeclaredMonitors.new(config:)
      @overrides = Overrides.new(config:)
      @client = client || Client.new(config)
      @app = app || default_app_name
    end

    # @param prune [Boolean] a `PRUNE=1` run: send the flag and the key list that
    #   bounds it (see #declared_keys). Retirement is the server's decision to
    #   make and its own rule to apply — there is deliberately no client-supplied
    #   list of keys to retire (§6.1).
    # @return [Result] the whole run — count, reasons, orphans, retirements — or
    #   nil on a sync FAILURE (logged, swallowed). The two are different objects
    #   because `{}` is truthy: see Result.
    def sync!(prune: false)
      entries = payload
      # No request on an empty payload. §6.1's two parse-empty paths exit
      # non-zero before one is made, which is also what keeps an empty parse from
      # so much as REPORTING orphans, let alone retiring them. The Result still
      # carries the registrars' skips — "nothing registered" is only actionable
      # beside the reason nothing could be.
      return Result.new(entries:, skips:) if entries.empty?

      # A prune this run cannot bound is a prune it must not send.
      pruning = prune && prunable?
      result = Result.new(entries:, skips:, response: send_entries(entries, prune: pruning),
                          pruned: pruning, prune_suppressed: prune && !pruning)
      log_skipped(result)
      log_suppressed_prune if result.prune_suppressed?
      result
    rescue ConfigurationError
      # Deliberately ahead of the catch-all below: a config error is not a sync
      # failure and must not become a warning and a green deploy. §3.1 fails the
      # whole run on one, and by construction it has already happened before any
      # request was made.
      raise
    rescue StandardError => e
      log_warn("sync failed: #{e.class}: #{e.message}")
      nil
    end

    # What a sync from here WOULD send, computed without sending it — §6.6's
    # dry-run preview, and the reason install can show a real derivation before
    # any deploy has happened.
    #
    # The same Result the empty-payload path above answers (entries and skips,
    # no response), so install and sync report from one object and cannot drift
    # into describing the payload differently. A ConfigurationError propagates,
    # exactly as it does for a real run: an override typo is a typo whether or
    # not this run intended to register anything.
    #
    # @return [Result]
    def preview
      Result.new(entries: payload, skips:)
    end

    private
      attr_reader :config

      def send_entries(entries, prune:)
        @client.sync_monitors(app: @app, monitors: entries.map { |entry| entry.slice(*WIRE_KEYS) },
                              **prune_params(prune))
      end

      # The flag and the key list ride together or not at all: the server retires
      # nothing on a prune request that carries no `declared_keys` (every
      # pre-0.2.0 gem), and sending the list without the flag would be a
      # retire-set computed for a run that never asked to retire anything.
      def prune_params(prune)
        return {} unless prune

        { prune: true, declared_keys: }
      end

      # Whether a prune can be BOUNDED this run — the guard the whole feature
      # rests on. The server retires every orphan absent from `declared_keys`,
      # so a list that is short because the registrar read nothing retires the
      # lot: "a broken parse deletes everything" is the incident §6.1 spends a
      # section making unreachable.
      #
      # Checked against the recurring registrar alone, deliberately: c.monitors
      # keys are always in the payload, so a run carrying nothing but
      # declarations would look non-empty and still omit every task key. The cost
      # is that a host with only c.monitors cannot prune at all — accepted, since
      # a stale monitor there is still deletable in the dashboard, and the
      # alternative is a wrong retirement of everything.
      def prunable?
        @registrar.declares_tasks?
      end

      def log_suppressed_prune
        log_warn("PRUNE was requested and NOT applied: no task was found in #{config.recurring_path} for " \
                 "environment '#{config.environment}', so this run cannot tell a removed task from a file " \
                 "it failed to read. Nothing was retired.")
      end

      # Every task key this run's registrars can SEE, before their skips (§6.1).
      # The guard only the CLI can supply: a task still IN recurring.yml whose
      # class: line was deleted is skipped, stops matching its monitor and reads
      # to the server as an orphan — retiring it would turn a YAML typo into
      # monitoring-off for a live job. Present in this list, it is reported as
      # present-but-not-registerable and never retired.
      def declared_keys
        (@registrar.declared_keys + @declared.declared_keys).uniq
      end

      # Both registrars', because the report prints one list and the reader does
      # not care which half of the config a skipped job was declared in.
      def skips
        @registrar.skips + @declared.skips
      end

      # The may-register set: recurring.yml PLUS c.monitors, merged HERE and not
      # inside the registrar (§6.3). Fold c.monitors into the registrar and
      # `registrar.tuples` — the set Registrar#reportable_class_to_keys
      # intersects class_to_keys against — starts carrying keys that have no job
      # class, so a declaration named after a host job class would let that class
      # check in for the shell script's monitor.
      #
      # Overrides are applied first and against the DERIVED tuples only, which is
      # also §6.1's order: parse, then override validation, then the
      # register-nothing exit above. Validating after that exit would mask an
      # override typo on exactly the run that is already going wrong.
      def payload
        declared = @declared.tuples
        derived = @overrides.apply_to(@registrar.tuples,
                                      declared_keys: declared.map { |tuple| tuple[:registration_key] })

        reject_collisions(derived + declared)
      end

      # §6.3 — a c.monitors key that repeats a recurring.yml task key used to
      # resolve last-wins with no warning. One key is one monitor, so the two
      # declarations fight over its interval and the winner depends on merge
      # order; the user has to say which one they meant.
      def reject_collisions(entries)
        repeated = entries.map { |entry| entry[:registration_key] }.tally.select { |_key, count| count > 1 }.keys
        return entries if repeated.empty?

        raise ConfigurationError,
              "two declarations register the same monitor: #{repeated.map(&:inspect).join(', ')}. A " \
              "c.monitors key must not repeat a task key from #{config.recurring_path} — rename the " \
              "declaration, or drop it and let the task register."
      end

      # The server registers what it can and returns the rest under `skipped`.
      # Those jobs are NOT monitored, so name each one and say why rather than
      # dropping the list on the floor — in the LOG as well as in the command's
      # report, since a sync run from a deploy hook and a sync run watched by a
      # human are the same code and only one of them has someone reading stdout.
      def log_skipped(result)
        result.skipped.each do |skip|
          log_warn("the server did not register '#{skip[:registration_key]}' (#{skip[:reason]}) — " \
                   "that job is NOT monitored.")
        end
      end

      def default_app_name
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.class.module_parent_name.to_s.underscore
        else
          "app"
        end
      rescue StandardError
        "app"
      end
  end
end
