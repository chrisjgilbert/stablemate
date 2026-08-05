require "test_helper"
require_relative "../../config/initializers/deployment_config"

# The env → production-config mapping, as a plain object over a plain hash.
#
# This logic used to sit inline in config/environments/production.rb, where the
# only way to reach it was to boot a whole production process per case — 8 boots,
# ~34s, to assert things like "a blank SMTP_PORT falls back to 587". The rules
# themselves never needed a Rails process; they needed an argument. One boot
# smoke test (production_env_config_test.rb) still proves production actually
# wires this object in.
class DeploymentConfigTest < ActiveSupport::TestCase
  # Positional credentials, not a keyword: with a keyword in the signature Ruby
  # reads `config_for("A" => "b")` as keywords rather than a hash argument.
  def config_for(env = {}, credentials = {})
    Stablemate::DeploymentConfig.new(env, credentials: credentials)
  end

  # --- SSL -----------------------------------------------------------------

  test "SSL is forced by default" do
    assert config_for.ssl_enabled?
  end

  test "an explicit false disables forced SSL for plain-HTTP self-hosting" do
    assert_not config_for("STABLEMATE_FORCE_SSL" => "false").ssl_enabled?
    assert_not config_for("STABLEMATE_FORCE_SSL" => "0").ssl_enabled?
  end

  # A blank value is the dangerous case: `STABLEMATE_FORCE_SSL=` in a compose file
  # is present-but-empty, and casting that directly would drop the Secure flag off
  # the session cookie and the ping token.
  test "a blank value still forces SSL — never silently insecure" do
    assert config_for("STABLEMATE_FORCE_SSL" => "").ssl_enabled?
    assert config_for("STABLEMATE_FORCE_SSL" => "   ").ssl_enabled?
  end

  # --- host and protocol ---------------------------------------------------

  test "the managed default host is used when the operator sets none" do
    assert_equal "stablemate.dev", config_for.host
  end

  test "STABLEMATE_HOST drives the mailer host, port and all" do
    assert_equal "status.example.com", config_for("STABLEMATE_HOST" => "status.example.com").host
    assert_equal "localhost:3000", config_for("STABLEMATE_HOST" => "localhost:3000").host
  end

  test "the protocol follows SSL unless it is set explicitly" do
    assert_equal "https", config_for.protocol
    assert_equal "http", config_for("STABLEMATE_FORCE_SSL" => "false").protocol
    assert_equal "https", config_for("STABLEMATE_PROTOCOL" => "https", "STABLEMATE_FORCE_SSL" => "false").protocol
  end

  # --- host authorization --------------------------------------------------

  # The managed Kamal deploy sets neither variable and may be reached on
  # apex/www/IP/CDN-rewritten Host headers, so host authorization must stay OFF
  # by default rather than 403 traffic that used to be served.
  test "host authorization is off unless the operator opts in" do
    assert_empty config_for.allowed_hosts
    assert_not config_for.host_authorization?
  end

  test "a configured host allows the bare host, with the port stripped for matching" do
    config = config_for("STABLEMATE_HOST" => "localhost:3000")

    assert_includes config.allowed_hosts, "localhost"
    assert_not_includes config.allowed_hosts, "localhost:3000"
    assert config.host_authorization?
  end

  test "STABLEMATE_HOSTS adds a comma-separated list, ignoring blanks and padding" do
    config = config_for("STABLEMATE_HOSTS" => " a.test , b.test ,, c.test:8080 ")

    assert_equal %w[a.test b.test c.test], config.allowed_hosts
  end

  test "a degenerate host entry never becomes a nil rule in config.hosts" do
    config = config_for("STABLEMATE_HOSTS" => ":,  :  ,real.test")

    assert_equal %w[real.test], config.allowed_hosts
    assert_not_includes config.allowed_hosts, nil
  end

  # --- trusted proxies -----------------------------------------------------

  test "no proxies are trusted beyond Rails' own private ranges by default" do
    assert_nil config_for.trusted_proxies,
      "nil leaves ActionDispatch::RemoteIp at its stock behaviour"
  end

  test "opting into Cloudflare trusts its published ranges on top of the private ones" do
    proxies = config_for("STABLEMATE_BEHIND_CLOUDFLARE" => "true").trusted_proxies

    assert_includes proxies, IPAddr.new("173.245.48.0/20")
    assert_includes proxies, IPAddr.new("2400:cb00::/32"), "the IPv6 ranges must come too"
    # Assigning trusted_proxies REPLACES Rails' defaults, so the built-in private
    # ranges have to be carried along or the kamal-proxy hop stops being stripped.
    assert (ActionDispatch::RemoteIp::TRUSTED_PROXIES - proxies).empty?,
      "Rails' private ranges must be preserved, not replaced"
  end

  test "arbitrary proxy CIDRs can be trusted" do
    proxies = config_for("STABLEMATE_TRUSTED_PROXIES" => "10.9.0.0/16, 192.0.2.1").trusted_proxies

    assert_includes proxies, IPAddr.new("10.9.0.0/16")
    assert_includes proxies, IPAddr.new("192.0.2.1")
  end

  # --- SMTP ----------------------------------------------------------------

  test "SMTP settings are read from the environment" do
    config = config_for(
      "SMTP_ADDRESS" => "smtp.provider.test", "SMTP_PORT" => "2525",
      "SMTP_USERNAME" => "postmaster", "SMTP_PASSWORD" => "s3cret", "SMTP_DOMAIN" => "example.com"
    )

    assert_equal "smtp.provider.test", config.smtp_settings[:address]
    assert_equal 2525, config.smtp_settings[:port]
    assert_equal "postmaster", config.smtp_settings[:user_name]
    assert_equal "example.com", config.smtp_settings[:domain]
  end

  test "a blank SMTP_PORT falls back to 587 instead of crashing boot" do
    assert_equal 587, config_for("SMTP_PORT" => "").smtp_settings[:port]
    assert_equal 587, config_for.smtp_settings[:port]
  end

  test "the environment beats credentials, and credentials beat the default" do
    credentials = { address: "creds.test", port: 2626, user_name: "creds-user" }

    assert_equal "env.test", config_for({ "SMTP_ADDRESS" => "env.test" }, credentials).smtp_settings[:address]
    assert_equal "creds.test", config_for({}, credentials).smtp_settings[:address]
    assert_equal 2626, config_for({}, credentials).smtp_settings[:port]
  end

  # An unauthenticated relay is a common self-host setup (a local Postfix, or an
  # internal SMTP that authorises by IP). Requesting AUTH anyway fails the send
  # with "SMTP-AUTH requested but missing user name".
  test "AUTH is only requested when a username is supplied" do
    without_user = config_for("SMTP_ADDRESS" => "relay.test").smtp_settings

    assert_not without_user.key?(:user_name)
    assert_not without_user.key?(:authentication)

    with_user = config_for("SMTP_ADDRESS" => "relay.test", "SMTP_USERNAME" => "u").smtp_settings

    assert_equal :plain, with_user[:authentication]
  end

  test "STARTTLS is on by default and a blank value does not disable it" do
    assert config_for.smtp_settings[:enable_starttls]
    assert config_for("SMTP_ENABLE_STARTTLS" => "").smtp_settings[:enable_starttls]
    assert_not config_for("SMTP_ENABLE_STARTTLS" => "false").smtp_settings[:enable_starttls]
  end

  # --- the two delivery regimes -------------------------------------------

  # F1 — a transient SMTP failure used to be swallowed: the delivery job
  # succeeded, the alert was gone, and the audit row still said "delivered".
  test "a configured relay delivers for real and lets failures raise" do
    config = config_for("SMTP_ADDRESS" => "smtp.provider.test")

    assert config.deliver_mail?
    assert config.raise_delivery_errors?
  end

  # …and the documented self-host tolerance survives: an instance with no SMTP
  # stays quiet rather than generating a perpetual failing-job storm.
  test "an instance with no SMTP configured neither attempts nor raises deliveries" do
    assert_not config_for.deliver_mail?
    assert_not config_for.raise_delivery_errors?
  end
end
