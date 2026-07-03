# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < StablemateTest
  # Safe by default: an api_key visible in every environment (e.g. shared Rails
  # credentials) must not make dev/test boots sync or ping — a laptop pinging a
  # production monitor masks real outages.
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
end
