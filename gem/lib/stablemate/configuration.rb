# frozen_string_literal: true

module Stablemate
  # A mistake in config/initializers/stablemate.rb that the run cannot resolve on
  # the user's behalf: an override naming a task that derives no interval, an
  # unknown setting inside one, a declaration with no interval, a c.monitors key
  # that repeats a recurring.yml task key.
  #
  # RAISED, not logged. §3.1 requires the whole run to fail, exit non-zero and
  # make no request: half-applying the rest would make the failure ambiguous, and
  # a typo'd override key that is merely ignored leaves the job wearing exactly
  # the window the override existed to correct. Registration#sync!'s rescue —
  # which turns a transport failure into a warning and carries on — lets this one
  # through on purpose, because it will not fix itself on the next deploy.
  class ConfigurationError < StandardError; end

  # Holds the gem's runtime config. Set via Stablemate.configure.
  class Configuration
    # The sm_live_… API key. REGISTRATION ONLY: `bin/rails stablemate:sync` sends
    # it to /api/v1. It is never on the check-in path — that is ping_key's job —
    # so a leaked check-in credential carries no management rights.
    attr_accessor :api_key
    # The sm_ping_… key every check-in authenticates with (Authorization: Bearer).
    # A distinct secret from api_key, and the only credential the hot path reads.
    attr_accessor :ping_key
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
    # Work that is not a Rails job — a shell cron, a backup script — declared in the
    # same place as everything else so it registers through the same command:
    #   c.monitors = { "pg_backup" => { interval: 86_400, grace: 7_200 } }
    # SECONDS are the canonical unit: `1.day` needs ActiveSupport and the gem
    # supports a plain-Ruby host. A missing grace is defaulted the way the registrar
    # defaults it. These keys have no job class by definition, so they never bind to
    # one and can never be checked in by the execution subscriber — their check-ins
    # come from the work itself (see the curl block `stablemate:install` prints).
    attr_accessor :monitors
    # Per-task overrides of the DERIVED interval/grace, keyed by recurring.yml task
    # key, in seconds:
    #   c.overrides = { "weekday_report" => { interval: 93_600 } }
    # Only interval: and grace: are accepted. This is the remedy for a derived
    # interval that is correct but useless — a weekday-only `0 9 * * 1-5` derives 72
    # hours from the Friday→Monday gap. Validation (unknown keys, keys matching no
    # derived task) lives in the sync command, the only place that knows which tasks
    # were derived.
    attr_accessor :overrides
    # DEPRECATED and ignored: boot no longer registers anything — registration is
    # `bin/rails stablemate:sync`. The accessor stays because it is documented public
    # config that hosts have in a committed initializer: deleting it would raise
    # NoMethodError inside the host's own initializer and the app would not boot. So
    # assignment is accepted, logged once, and otherwise has no effect.
    attr_reader :register_on_boot
    # Path to the Solid Queue recurring config (override for tests).
    attr_accessor :recurring_path
    # Network timeout (seconds) for all HTTP calls — kept short; the hot path must
    # never block a job.
    attr_accessor :timeout
    # Pluggable logger (responds to #warn / #info). Defaults to a stderr logger.
    attr_accessor :logger

    def initialize
      # One name everywhere — these are the names `stablemate:install` takes as
      # arguments, writes into the initializer skeleton and appends to .env.
      @api_key = env_value("STABLEMATE_API_KEY")
      @ping_key = env_value("STABLEMATE_PING_KEY")
      @endpoint = ENV.fetch("STABLEMATE_ENDPOINT", "https://stablemate.dev")
      @environments = [ "production" ]
      @environment = nil
      @monitors = {}
      @overrides = {}
      @ping_on_success = true
      @ping_on_failure = true
      @register_on_boot = true
      @recurring_path = "config/recurring.yml"
      @timeout = 2
      @logger = nil
      @warned_about_register_on_boot = false
    end

    def register_on_boot=(value)
      @register_on_boot = value
      warn_register_on_boot_is_a_no_op
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
      # A set-but-empty var (`STABLEMATE_PING_KEY=` in a unit file or a .env) is
      # truthy in Ruby. Left as "", the boot gate would pass and every check-in
      # would carry `Authorization: Bearer ` for a permanent 401 — the same trap
      # default_environment already guards against for RAILS_ENV.
      def env_value(name)
        value = ENV[name]
        value unless value.nil? || value.empty?
      end

      # Once per configuration, and the flag is set BEFORE the IO: the
      # check-log-set shape duplicates whenever the logging releases the GVL.
      # Swallows its own errors — the logger is pluggable public API, and a broken
      # sink must not take the host's initializer down with it.
      def warn_register_on_boot_is_a_no_op
        return if @warned_about_register_on_boot

        @warned_about_register_on_boot = true
        (logger || Stablemate.logger).warn(
          "[stablemate] register_on_boot no longer does anything and can be removed: boot only " \
          "attaches the check-in listener now, and monitors are registered by `bin/rails stablemate:sync`."
        )
      rescue StandardError
        nil
      end

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
