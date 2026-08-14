# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < StablemateTest
  # Safe by default — see the rationale on Configuration#environments.
  def test_auto_wiring_defaults_to_production_only
    config = Stablemate::Configuration.new

    assert config.enabled_in?("production")
    refute config.enabled_in?("development")
    refute config.enabled_in?("test")
    refute config.enabled_in?("staging")
  end

  def test_environments_can_opt_in_staging
    config = Stablemate::Configuration.new
    config.environments = %w[production staging]

    assert config.enabled_in?("staging")
    refute config.enabled_in?("development")
  end

  # §11 — register_on_boot is a DEPRECATED NO-OP, and the accessor must survive.
  # Hosts have `c.register_on_boot = false` in a committed initializer; deleting
  # the accessor raises NoMethodError inside that initializer and the host app
  # does not boot. So: assigning it is accepted, logged, and otherwise ignored.
  # (A test asserting the old default stays green while proving nothing.)
  def test_register_on_boot_is_a_deprecated_no_op_that_still_accepts_assignment
    logger = Stablemate::RecordingLogger.new
    config = Stablemate::Configuration.new
    config.logger = logger

    config.register_on_boot = false

    assert_equal 1, logger.warnings.size
    assert_match(/register_on_boot/, logger.warnings.first)
    # Names the replacement, or the reader has no idea what to do instead.
    assert_match(/stablemate:sync/, logger.warnings.first)
  end

  # Once per config, not once per assignment — a deprecation that prints on every
  # line of a re-entrant initializer is noise the reader learns to skip.
  def test_register_on_boot_is_logged_once
    logger = Stablemate::RecordingLogger.new
    config = Stablemate::Configuration.new
    config.logger = logger

    3.times { config.register_on_boot = false }

    assert_equal 1, logger.warnings.size
  end

  # The reader is public API too (a host may branch on it), so it must not raise.
  def test_register_on_boot_reads_back_without_raising
    config = Stablemate::Configuration.new
    config.logger = Stablemate::RecordingLogger.new

    config.register_on_boot = false

    refute config.register_on_boot
  end

  # A broken sink must not take the host's initializer down with it.
  def test_register_on_boot_survives_a_raising_logger
    config = Stablemate::Configuration.new
    config.logger = Stablemate::RaisingLogger.new(IOError.new("closed"))

    config.register_on_boot = false
  end

  # Terminal-failure reporting is ON by default, symmetric with ping_on_success.
  def test_ping_on_failure_defaults_true
    config = Stablemate::Configuration.new

    assert config.ping_on_failure

    config.ping_on_failure = false
    refute config.ping_on_failure
  end

  # nil restores key-presence-only gating for hosts that want it everywhere.
  def test_nil_environments_enables_everywhere
    config = Stablemate::Configuration.new
    config.environments = nil

    assert config.enabled_in?("development")
    assert config.enabled_in?("production")
  end

  # Rails.env is an ActiveSupport::StringInquirer, symbols are plausible input —
  # comparison must not depend on the caller's type.
  def test_enabled_in_compares_loosely
    config = Stablemate::Configuration.new
    config.environments = [ :production ]

    assert config.enabled_in?("production")
  end

  # `c.environments = "production"` (bare String instead of an array) is a
  # natural typo. It must ENABLE production, not raise NoMethodError — the
  # railtie's blanket rescue would turn that into monitoring silently disabled
  # in the very environment the user tried to enable.
  def test_environments_accepts_a_bare_string_or_symbol
    config = Stablemate::Configuration.new

    config.environments = "production"
    assert config.enabled_in?("production")
    refute config.enabled_in?("development")

    config.environments = :staging
    assert config.enabled_in?("staging")
  end

  # One shared answer to "what environment am I in": the registrar scopes
  # recurring.yml with it and the railtie gates on it, so they can't diverge.
  def test_environment_resolves_from_env_vars_with_blank_values_skipped
    with_env("RAILS_ENV" => nil, "RACK_ENV" => nil) do
      assert_equal "development", Stablemate::Configuration.new.environment
    end
    with_env("RAILS_ENV" => "staging", "RACK_ENV" => nil) do
      assert_equal "staging", Stablemate::Configuration.new.environment
    end
    # A set-but-empty var (RAILS_ENV= in a unit file / .env) is truthy in Ruby;
    # it must be treated as unset, not become the environment "".
    with_env("RAILS_ENV" => "", "RACK_ENV" => "production") do
      assert_equal "production", Stablemate::Configuration.new.environment
    end
  end

  def test_environment_can_be_overridden
    config = Stablemate::Configuration.new
    config.environment = "staging"
    assert_equal "staging", config.environment
  end

  # §4 — two credentials. The API key registers; the ping key checks in. Both read
  # from the environment under the names install writes, so one name is used
  # everywhere (arguments, initializer skeleton, .env append).
  def test_both_credentials_default_from_the_environment
    with_env("STABLEMATE_API_KEY" => "sm_live_from_env", "STABLEMATE_PING_KEY" => "sm_ping_from_env") do
      config = Stablemate::Configuration.new

      assert_equal "sm_live_from_env", config.api_key
      assert_equal "sm_ping_from_env", config.ping_key
    end
  end

  def test_credentials_are_nil_when_unset
    with_env("STABLEMATE_API_KEY" => nil, "STABLEMATE_PING_KEY" => nil) do
      config = Stablemate::Configuration.new

      assert_nil config.api_key
      assert_nil config.ping_key
    end
  end

  # A set-but-empty var is truthy in Ruby. Left as "", every check-in would carry
  # `Authorization: Bearer ` for a permanent 401 with nothing logged — the same
  # trap default_environment already guards for RAILS_ENV.
  def test_a_blank_credential_env_var_counts_as_unset
    with_env("STABLEMATE_API_KEY" => "", "STABLEMATE_PING_KEY" => "") do
      config = Stablemate::Configuration.new

      assert_nil config.api_key
      assert_nil config.ping_key
    end
  end

  def test_credentials_can_be_set_explicitly
    config = Stablemate::Configuration.new
    config.api_key = "sm_live_explicit"
    config.ping_key = "sm_ping_explicit"

    assert_equal "sm_live_explicit", config.api_key
    assert_equal "sm_ping_explicit", config.ping_key
  end

  # §3.1 — non-Rails work is declared in config, so it registers through the same
  # command. Seconds are canonical: 1.day needs ActiveSupport, and the gem
  # supports a plain-Ruby host.
  def test_monitors_defaults_to_empty_and_accepts_declarations
    config = Stablemate::Configuration.new

    assert_empty config.monitors

    config.monitors = { "pg_backup" => { interval: 86_400, grace: 7_200 } }

    assert_equal({ "pg_backup" => { interval: 86_400, grace: 7_200 } }, config.monitors)
  end

  # §3.1 — the only remedy for a derived interval that is correct but useless (a
  # weekday-only cron derives 72 hours from the Friday→Monday gap).
  def test_overrides_defaults_to_empty_and_accepts_declarations
    config = Stablemate::Configuration.new

    assert_empty config.overrides

    config.overrides = { "weekday_report" => { interval: 93_600 } }

    assert_equal({ "weekday_report" => { interval: 93_600 } }, config.overrides)
  end

  def test_enabled_in_defaults_to_the_resolved_environment
    with_env("RAILS_ENV" => "production", "RACK_ENV" => nil) do
      config = Stablemate::Configuration.new
      assert config.enabled_in?
    end
    with_env("RAILS_ENV" => "development", "RACK_ENV" => nil) do
      config = Stablemate::Configuration.new
      refute config.enabled_in?
    end
  end

  private
    def with_env(pairs)
      saved = pairs.keys.to_h { |k| [ k, ENV[k] ] }
      pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
end
