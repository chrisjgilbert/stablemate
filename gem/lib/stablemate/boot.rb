# frozen_string_literal: true

# String#presence. Required rather than assumed: relying on the host having
# loaded it is the same trap as `require "erb"` (§6.4) and `require "set"`
# (§6.3), and it is doubly hidden here because the boot rescue below would turn
# the resulting NoMethodError into "boot wiring skipped" — a silently disabled
# gem. Safe as a hard require because THIS FILE IS LOADED ONLY BY THE RAILTIE:
# a Rails host always has ActiveSupport, and a plain-Ruby host never reaches
# here (nothing in stablemate.rb requires this file).
require "active_support/core_ext/object/blank"

require_relative "registrars/solid_queue_recurring"
require_relative "execution/subscriber"

module Stablemate
  # What boot does, in full: attach the check-in listener (§6.5).
  #
  # It used to register every task in recurring.yml and fetch an address per
  # monitor, on every boot of every process. Registration is
  # `bin/rails stablemate:sync` now, and a check-in addresses itself by task key
  # — so there is nothing left to fetch, and boot touches the network zero times.
  #
  # Nothing here may crash the host: the rescue is the app's boot sequence, not
  # belt-and-braces (see #wire!).
  #
  # Deviation from §6.5's snippet, which inlines this in the railtie's
  # after_initialize block (per CLAUDE.md's say-so rule): the behaviour is
  # identical, but as an object it is testable without booting a Rails app —
  # and §12 asks for three boot cases, including one where the app must still
  # boot with a broken recurring.yml.
  class Boot
    include Logging

    NO_PING_KEY = "no ping_key configured — check-ins are DISABLED. Set STABLEMATE_PING_KEY " \
                  "(or c.ping_key in config/initializers/stablemate.rb) to a ping key from your " \
                  "project's setup panel."

    # @param subscriber_options [Hash] passed straight to Execution::Subscriber
    #   (client:, dispatcher:) — Boot chooses the map and the gates, and has no
    #   opinion about transport. This is also the seam the tests inject through.
    def initialize(config: Stablemate.config, **subscriber_options)
      @config = config
      @subscriber_options = subscriber_options
    end

    # @return [Execution::Subscriber, nil] the armed subscriber, or nil when a
    #   gate closed or something went wrong (both already logged).
    def wire!
      # Logged ABOVE the environment gate, deliberately: a developer booting
      # locally is told their deploy has no key even though the allow-list is
      # about to stop us wiring anything up. Now that boot does nothing else,
      # this line is the only signal a misconfigured deploy produces.
      #
      # .presence, not truthiness — a set-but-empty STABLEMATE_PING_KEY is "",
      # which is truthy: the gate would pass, this would never print, and every
      # check-in would carry `Authorization: Bearer ` for a permanent 401.
      log_error(NO_PING_KEY) if config.ping_key.presence.nil?

      # The allow-list is production-only by default and must survive: without it
      # a developer's laptop checks in to production monitors and masks a real
      # outage.
      return nil unless config.enabled_in?
      return nil unless config.ping_key.presence

      registrar = Registrars::SolidQueueRecurring.new(config:) # local YAML only, no network

      # subscribe_discards! ARMS terminal-failure reporting by assigning
      # Stablemate.execution_subscriber, the delegation target of the Base-level
      # hook installed by the railtie's initializer. Guarded inside, so older
      # hosts silently keep missed-beat-only detection.
      Execution::Subscriber
        .new(class_to_keys: registrar.reportable_class_to_keys, config:, **@subscriber_options)
        .subscribe!
        .subscribe_discards!
    rescue StandardError => e
      # Psych::SyntaxError is a StandardError, so dropping this rescue would turn
      # a broken recurring.yml from "monitoring off" into "the app will not
      # boot" — strictly worse than the bug it would be guarding.
      log_error("boot wiring skipped: #{e.class}: #{e.message}")
      nil
    end

    private
      attr_reader :config
  end
end
