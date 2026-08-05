require "test_helper"

# Self-hosting (#17) requires the production environment to be configured
# entirely from ENV — no in-repo Rails credentials.
#
# The RULES for that (a blank SMTP_PORT falling back to 587, a blank
# STABLEMATE_FORCE_SSL still forcing SSL, the port stripped from an allowed host)
# are Stablemate::DeploymentConfig's, and are tested in-process against a plain
# hash in deployment_config_test.rb — 19 cases, no boot. This file used to prove
# them by booting a production process each: ~34s for 8 cases, and still only 8.
#
# What a boot proves and an object cannot: that production.rb actually WIRES the
# object into Rails' config, and that a production process boots at all. That
# needs a real process, so one boot covers it — set every variable at once and
# read back the setting each is supposed to reach.
class ProductionEnvConfigTest < ActiveSupport::TestCase
  include BootTestHelper

  # Single-quoted heredoc: the script is code for the CHILD process, so nothing
  # in it may be interpolated here.
  BOOT_SCRIPT = <<~'RUBY'.freeze
    c = Rails.application.config
    puts({
      mailer_host: c.action_mailer.default_url_options[:host],
      mailer_protocol: c.action_mailer.default_url_options[:protocol],
      asset_host: c.action_mailer.asset_host,
      smtp_address: c.action_mailer.smtp_settings[:address],
      smtp_port: c.action_mailer.smtp_settings[:port],
      smtp_user: c.action_mailer.smtp_settings[:user_name],
      raise_delivery_errors: c.action_mailer.raise_delivery_errors,
      perform_deliveries: c.action_mailer.perform_deliveries,
      force_ssl: c.force_ssl,
      assume_ssl: c.assume_ssl,
      hosts: c.hosts.map(&:to_s),
      # IPAddr#to_s drops the prefix ("10.9.0.0/16" => "10.9.0.0"), so keep it.
      trusted_proxies: c.action_dispatch.trusted_proxies.to_a.map { |p| p.respond_to?(:prefix) ? "#{p}/#{p.prefix}" : p.to_s }
    }.to_json)
  RUBY

  # SECRET_KEY_BASE because production demands one and there are no in-repo
  # credentials to supply it; DISABLE_DATABASE_ENVIRONMENT_CHECK because the boot
  # points at the test database.
  PRODUCTION_ENV = {
    "RAILS_ENV" => "production",
    "SECRET_KEY_BASE" => "test-secret-key-base",
    "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1"
  }.freeze

  # Every knob at once, each with a value distinctive enough to trace back to the
  # setting it is supposed to drive. The blank SMTP_PORT rides along deliberately:
  # it is the value that used to crash boot via Integer(""), so a boot is exactly
  # where it is worth re-checking.
  test "a production instance boots and wires the environment through to Rails' config" do
    cfg = boot_app(BOOT_SCRIPT, PRODUCTION_ENV.merge(
      "STABLEMATE_HOST" => "status.example.com:8443",
      "STABLEMATE_PROTOCOL" => "https",
      "STABLEMATE_TRUSTED_PROXIES" => "10.9.0.0/16",
      "SMTP_ADDRESS" => "smtp.provider.test",
      "SMTP_PORT" => "",
      "SMTP_USERNAME" => "postmaster"
    ))

    # URL building keeps the port; host authorization matches the bare host.
    assert_equal "status.example.com:8443", cfg["mailer_host"]
    assert_equal "https", cfg["mailer_protocol"]
    assert_equal "https://status.example.com:8443", cfg["asset_host"]
    assert_includes cfg["hosts"], "status.example.com"
    assert_not_includes cfg["hosts"], "status.example.com:8443"

    assert_equal "smtp.provider.test", cfg["smtp_address"]
    assert_equal 587, cfg["smtp_port"], "a blank SMTP_PORT must fall back, not crash the boot"
    assert_equal "postmaster", cfg["smtp_user"]

    # F1 — with SMTP configured, a failed send must fail the job so the retry
    # layer re-sends it rather than silently discarding an alert.
    assert_equal true, cfg["perform_deliveries"]
    assert_equal true, cfg["raise_delivery_errors"]

    assert_includes cfg["trusted_proxies"], "10.9.0.0/16"
  end

  # The other deployment shape, and the one a self-hoster meets first: nothing
  # configured. It must boot, stay quiet about mail, and — critically — not turn
  # host authorization on, since the managed Kamal deploy sets no STABLEMATE_HOST
  # and is reached on apex/www/IP/CDN-rewritten Host headers that a single
  # allow-list entry would 403.
  test "an unconfigured production instance boots, stays quiet, and authorises every host" do
    cfg = boot_app(BOOT_SCRIPT, PRODUCTION_ENV)

    assert_empty cfg["hosts"]
    assert_nil cfg["smtp_address"]
    assert_equal false, cfg["perform_deliveries"], "no relay to retry against — no failing-job storm"
    assert_equal false, cfg["raise_delivery_errors"]
    assert_equal true, cfg["force_ssl"], "the default must never be silently insecure"
  end
end
