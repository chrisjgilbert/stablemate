# frozen_string_literal: true

module Stablemate
  # One `{ interval:, grace: }` pair exactly as the user wrote it in their
  # initializer — either a `c.monitors` declaration of work that is not a Rails
  # job (§6.3) or a `c.overrides` correction to a derived interval (§3.1). Both
  # accept the same two settings in the same unit, and the three rules they share
  # live here so the two cannot drift:
  #
  # - **Integer seconds is the unit**, and Numeric is the test. `"26 hours".to_i`
  #   is 26, so a stray string would silently register a 26-SECOND window and page
  #   the user on every run. An ActiveSupport::Duration passes (it answers
  #   `is_a?(Numeric)`), so a Rails host may write `1.day` even though seconds are
  #   what the docs promise — the gem also supports a plain-Ruby host, where
  #   `1.day` does not exist.
  # - **An unknown setting is an error**, not a shrug: `intervall:` read as "no
  #   interval given" is the exact silent typo §3.1 writes the outer rule for. The
  #   key's TYPE is not policed — an initializer is Ruby, so both `interval:` and
  #   `"interval" =>` turn up — only its name.
  # - **Grace defaults from the interval it is paired with**: 15%, floored at five
  #   minutes, the same rule the registrar derives with. Which interval matters —
  #   an interval-only override recomputes grace from the OVERRIDDEN interval, or a
  #   26-hour override ends up wearing a 72-hour schedule's grace.
  #
  # Every message names `source`, the expression the user would recognise
  # (`c.monitors["pg_backup"]`). These errors fail the whole run before any
  # request, so the key is the only route back to the line that caused it.
  class Declaration
    SETTINGS = %i[interval grace].freeze
    DEFAULT_GRACE_FRACTION = 0.15
    MIN_GRACE_SECONDS = 5 * 60

    # The default grace rule, in one place: a derived task, a declaration that
    # omits grace, and an override that changes the interval all read it here.
    def self.default_grace(interval)
      [ (interval * DEFAULT_GRACE_FRACTION).round, MIN_GRACE_SECONDS ].max
    end

    def initialize(settings, source:)
      @source = source
      @settings = validated(settings)
    end

    # @return [Integer, nil] whole seconds, or nil when the setting is absent —
    #   never nil for one that is present and unusable, which raises instead.
    def interval = seconds(:interval)

    def grace = seconds(:grace)

    # @param interval [Integer] the interval this declaration will register with,
    #   which for an override is the overridden one.
    def grace_for(interval) = grace || self.class.default_grace(interval)

    private
      attr_reader :source, :settings

      def validated(raw)
        unless raw.is_a?(Hash)
          raise ConfigurationError,
                "#{source} must be a Hash of #{setting_list} in seconds, e.g. { interval: 86_400 } — " \
                "got #{raw.inspect}."
        end

        # to_s.to_sym, not to_sym: an Integer key has no #to_sym, and a garbage key
        # must be reported as an unknown setting rather than raise NoMethodError.
        normalized = raw.transform_keys { |name| name.to_s.to_sym }
        unknown = normalized.keys - SETTINGS
        unless unknown.empty?
          raise ConfigurationError,
                "#{source} has unknown setting#{"s" if unknown.size > 1} " \
                "#{unknown.map(&:inspect).join(', ')} — only #{setting_list} are accepted."
        end

        normalized
      end

      def seconds(name)
        return nil unless settings.key?(name)

        value = settings[name]
        cast = value.to_i if value.is_a?(Numeric)
        return cast if cast&.positive?

        raise ConfigurationError,
              "#{source} sets #{name}: to #{value.inspect}, which is not a positive number of " \
              "SECONDS. Seconds are the unit because the gem supports a plain-Ruby host; on a Rails " \
              "host 1.day works too."
      end

      def setting_list = SETTINGS.map { |name| "#{name}:" }.join(" / ")
  end
end
