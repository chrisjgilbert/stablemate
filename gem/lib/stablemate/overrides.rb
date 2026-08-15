# frozen_string_literal: true

require_relative "declaration"

module Stablemate
  # `c.overrides` — the only remedy left for a derived interval that is correct
  # and useless (§3.1), now that the edit form is gone:
  #
  #   c.overrides = { "weekday_report" => { interval: 93_600 } }
  #
  # The derived interval is the LARGEST gap between runs, so `0 9 * * 1-5` derives
  # 72 hours (Friday → Monday). Correct by construction — anything tighter
  # false-alarms every weekend — and useless to the user who wants to know on
  # Tuesday.
  #
  # They apply to DERIVED tasks only, and "derived" means after the registrar's
  # skips: a command-only task and an unsizable schedule produce no tuple, so
  # there is nothing to override. A key matching nothing fails the whole run
  # rather than being ignored, because ignoring it leaves the weekday job wearing
  # the 72-hour window the override existed to close — the precise failure this
  # setting is for.
  class Overrides
    def initialize(config: Stablemate.config)
      @config = config
    end

    # @param tuples [Array<Hash>] the registrar's DERIVED tuples, after its skips.
    # @param declared_keys [Array<String>] the `c.monitors` keys. Not overridable
    #   — they carry their own interval — but named apart in the error, because
    #   "matches no derived task" would send the user hunting through
    #   recurring.yml for a key that is sitting in their initializer.
    # @return [Array<Hash>] the tuples, overridden. The originals are not edited:
    #   §6.1's output prints the derived value beside the override.
    # @raise [ConfigurationError] before the caller has made any request.
    def apply_to(tuples, declared_keys: [])
      return tuples if overrides.empty?

      derived_keys = tuples.map { |tuple| tuple[:registration_key] }
      overrides.each_key { |key| validate!(key, derived_keys, declared_keys) }

      tuples.map { |tuple| override(tuple) }
    end

    private
      attr_reader :config

      # Keyed by task key, as strings: recurring.yml keys arrive from YAML as
      # strings and an initializer may write either, so the two must compare.
      def overrides
        @overrides ||= config.overrides.to_h.transform_keys(&:to_s)
      end

      def validate!(key, derived_keys, declared_keys)
        return if derived_keys.include?(key)

        raise ConfigurationError, unmatched(key, derived_keys, declared_keys)
      end

      def unmatched(key, derived_keys, declared_keys)
        if declared_keys.include?(key)
          "c.overrides[#{key.inspect}] overrides a c.monitors declaration, which already carries its " \
          "own interval — edit the declaration instead. Overrides correct intervals DERIVED from " \
          "#{config.recurring_path}."
        else
          # Naming the environment matters as much as naming the key: recurring.yml
          # is section-scoped, so the commonest miss that is NOT a typo is a run in
          # the wrong environment, where the task genuinely does not exist.
          "c.overrides[#{key.inspect}] matches no task whose interval is derived from " \
          "#{config.recurring_path} in environment '#{config.environment}' " \
          "(#{derived_summary(derived_keys)}). A command-only task and a schedule whose interval " \
          "cannot be derived are both skipped, so there is nothing to override for them — give the " \
          "task a class: and a sizable schedule, or declare the work in c.monitors."
        end
      end

      def derived_summary(derived_keys)
        return "nothing was derived there" if derived_keys.empty?

        "derived: #{derived_keys.join(', ')}"
      end

      def override(tuple)
        settings = overrides[tuple[:registration_key]]
        return tuple if settings.nil?

        declaration = Declaration.new(settings, source: "c.overrides[#{tuple[:registration_key].inspect}]")
        # An interval-only override recomputes grace from the OVERRIDDEN interval
        # (§3.1); the schedule-derived grace is not kept, and an explicit grace:
        # wins over both.
        interval = declaration.interval || tuple[:expected_interval_seconds]

        tuple.merge(expected_interval_seconds: interval,
                    grace_period_seconds: declaration.grace_for(interval),
                    # Provenance, not payload. §6.1's report names the derived
                    # value beside the override — "every 26h (override — derived
                    # 72h from '0 9 * * 1-5')" — which is what makes the
                    # largest-gap surprise visible at the moment the user can
                    # still fix it. Registration slices it off before the
                    # request; the server has no business seeing it.
                    derived_interval_seconds: tuple[:expected_interval_seconds])
      end
  end
end
