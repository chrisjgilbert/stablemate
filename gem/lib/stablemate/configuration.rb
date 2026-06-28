# frozen_string_literal: true

module Stablemate
  # Holds the gem's runtime config. Set via Stablemate.configure.
  class Configuration
    # The sm_live_… API key (used for /api/v1 registration; NOT on the ping hot path).
    attr_accessor :api_key
    # Base URL of the Stablemate server, e.g. "https://stablemate.dev".
    attr_accessor :endpoint
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
      @endpoint = "https://stablemate.dev"
      @ping_on_success = true
      @recurring_path = "config/recurring.yml"
      @timeout = 2
      @logger = nil
    end
  end
end
