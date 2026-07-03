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
