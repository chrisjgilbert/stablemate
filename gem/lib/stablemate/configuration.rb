# frozen_string_literal: true

module Stablemate
  # Holds the gem's runtime config. Set via Stablemate.configure.
  class Configuration
    # The sm_live_… API key (used for /api/v1 registration; NOT on the ping hot path).
    attr_accessor :api_key
    # Base URL of the Stablemate server, e.g. "https://stablemate.dev".
    attr_accessor :endpoint
    # Environments where the railtie auto-wires. Defaults to production only, so an
    # api_key visible in every environment can't make dev/test boots register
    # monitors or ping them — a laptop pinging a production monitor masks real
    # outages. Accepts an array, a bare String/Symbol, or nil (wire wherever an
    # api_key is present).
    attr_accessor :environments
    # Resolved lazily: Rails.env when Rails is present, else the first non-blank of
    # RAILS_ENV / RACK_ENV, else "development" — an unconfigured process must not
    # touch production monitors.
    attr_writer :environment
    # Whether a successful job perform fires a ping.
    attr_accessor :ping_on_success
    # Whether a TERMINAL job failure (unhandled raise, retry_on exhausted, or
    # discard_on) reports the error to the monitor. Attempts that will be retried
    # never report.
    attr_accessor :ping_on_failure
    # Whether the railtie auto-registers monitors from config/recurring.yml on boot.
    # With it off, boot still attaches the execution subscriber and fetches existing
    # monitors' ping URLs read-only, so successful runs still check in — the gem
    # just never creates or edits monitors from recurring.yml.
    attr_accessor :register_on_boot
    # Path to the Solid Queue recurring config (override for tests).
    attr_accessor :recurring_path
    # Network timeout (seconds) for all HTTP calls — kept short; the hot path must
    # never block a job.
    attr_accessor :timeout
    # Pluggable logger (responds to #warn / #info). Defaults to a stderr logger.
    attr_accessor :logger

    def initialize
      @endpoint = ENV.fetch("STABLEMATE_ENDPOINT", "https://stablemate.dev")
      @environments = [ "production" ]
      @environment = nil
      @ping_on_success = true
      @ping_on_failure = true
      @register_on_boot = true
      @recurring_path = "config/recurring.yml"
      @timeout = 2
      @logger = nil
    end

    def environment
      @environment ||= default_environment
    end

    # Loose comparison: Rails.env is a StringInquirer, configured entries may be
    # symbols, and a bare String/Symbol instead of an array is a natural typo that
    # must mean "that one environment", not raise into the railtie's rescue (which
    # would silently disable monitoring).
    def enabled_in?(env = environment)
      environments.nil? || Array(environments).any? { |e| e.to_s == env.to_s }
    end

    private
      def default_environment
        if defined?(Rails) && Rails.respond_to?(:env) && Rails.env
          Rails.env.to_s
        else
          # A set-but-empty var (`RAILS_ENV=` in a unit file) must count as unset,
          # not become the environment "".
          [ ENV["RAILS_ENV"], ENV["RACK_ENV"] ].find { |e| e && !e.empty? } || "development"
        end
      end
  end
end
