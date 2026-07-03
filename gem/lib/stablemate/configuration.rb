# frozen_string_literal: true

module Stablemate
  # Holds the gem's runtime config. Set via Stablemate.configure.
  class Configuration
    # The sm_live_… API key (used for /api/v1 registration; NOT on the ping hot path).
    attr_accessor :api_key
    # Base URL of the Stablemate server, e.g. "https://stablemate.dev".
    attr_accessor :endpoint
    # Environments where the railtie auto-wires (boot sync + execution
    # subscriber). Defaults to production only, so an api_key visible in every
    # environment (e.g. shared Rails credentials) can't make dev/test boots
    # register monitors or ping them — a laptop pinging a production monitor
    # masks real outages. Add "staging" to monitor staging too, or set nil to
    # wire wherever an api_key is present. `rails stablemate:sync` is an
    # explicit command and is not gated by this.
    attr_accessor :environments
    # Whether a successful job perform fires a ping.
    attr_accessor :ping_on_success
    # Path to the Solid Queue recurring config (override for tests).
    attr_accessor :recurring_path
    # Network timeout (seconds) for all HTTP calls — kept short; the hot path
    # must never block a job.
    attr_accessor :timeout
    # Pluggable logger (responds to #warn / #info). Defaults to a stderr logger.
    attr_accessor :logger

    def initialize
      # Defaults to the managed instance, but a self-hosted user points the gem at
      # their own server either by setting Stablemate.config.endpoint in an
      # initializer or via the STABLEMATE_ENDPOINT env var.
      @endpoint = ENV.fetch("STABLEMATE_ENDPOINT", "https://stablemate.dev")
      @environments = [ "production" ]
      @ping_on_success = true
      @recurring_path = "config/recurring.yml"
      @timeout = 2
      @logger = nil
    end

    # Should the railtie auto-wire in this environment? Loose comparison:
    # Rails.env is a StringInquirer, configured entries may be symbols.
    def enabled_in?(env)
      environments.nil? || environments.map(&:to_s).include?(env.to_s)
    end
  end
end
