require "test_helper"
require "open3"

# Self-hosting (#17) requires the production environment to be configured entirely
# from ENV — no in-repo Rails credentials. We can't flip the running test process
# into the production environment, so we boot a throwaway production process with
# the relevant env vars set and read the resulting config back out. This proves a
# self-hoster's STABLEMATE_HOST / SMTP_* / SECRET_KEY_BASE actually drive the app.
class ProductionEnvConfigTest < ActiveSupport::TestCase
  def boot_production(env)
    script = <<~RUBY
      c = Rails.application.config
      data = {
        mailer_host: c.action_mailer.default_url_options[:host],
        mailer_protocol: c.action_mailer.default_url_options[:protocol],
        smtp_address: c.action_mailer.smtp_settings[:address],
        smtp_port: c.action_mailer.smtp_settings[:port],
        smtp_user: c.action_mailer.smtp_settings[:user_name],
        force_ssl: c.force_ssl,
        hosts: c.hosts.map(&:to_s)
      }
      puts data.to_json
    RUBY

    base = {
      "RAILS_ENV" => "production",
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1"
    }
    out, err, status = Open3.capture3(base.merge(env), "bin/rails", "runner", script,
                                       chdir: Rails.root.to_s)
    assert status.success?, "production boot failed: #{err}"
    JSON.parse(out.lines.last)
  end

  test "STABLEMATE_HOST drives the mailer host and protocol" do
    cfg = boot_production(
      "STABLEMATE_HOST" => "status.example.com",
      "STABLEMATE_PROTOCOL" => "https"
    )
    assert_equal "status.example.com", cfg["mailer_host"]
    assert_equal "https", cfg["mailer_protocol"]
    assert_includes cfg["hosts"], "status.example.com"
  end

  test "SMTP settings are read from the environment" do
    cfg = boot_production(
      "STABLEMATE_HOST" => "example.com",
      "SMTP_ADDRESS" => "smtp.provider.test",
      "SMTP_PORT" => "2525",
      "SMTP_USERNAME" => "postmaster"
    )
    assert_equal "smtp.provider.test", cfg["smtp_address"]
    assert_equal 2525, cfg["smtp_port"]
    assert_equal "postmaster", cfg["smtp_user"]
  end

  test "STABLEMATE_FORCE_SSL=false disables forced SSL for plain-HTTP self-hosting" do
    cfg = boot_production(
      "STABLEMATE_HOST" => "localhost",
      "STABLEMATE_PROTOCOL" => "http",
      "STABLEMATE_FORCE_SSL" => "false"
    )
    assert_equal false, cfg["force_ssl"]
    assert_equal "http", cfg["mailer_protocol"]
  end

  test "a blank STABLEMATE_FORCE_SSL still forces SSL (never silently insecure)" do
    cfg = boot_production("STABLEMATE_HOST" => "example.com", "STABLEMATE_FORCE_SSL" => "")
    assert_equal true, cfg["force_ssl"]
  end

  test "a blank SMTP_PORT falls back to 587 instead of crashing boot" do
    cfg = boot_production("STABLEMATE_HOST" => "example.com", "SMTP_PORT" => "")
    assert_equal 587, cfg["smtp_port"]
  end

  test "host authorization is OFF unless STABLEMATE_HOST/STABLEMATE_HOSTS is set" do
    # The managed Kamal deploy sets neither, so the default must not start
    # rejecting Host headers (apex/www/IP/CDN-rewritten) that used to be served.
    cfg = boot_production({})
    refute_includes cfg["hosts"], "stablemate.dev"
    assert_empty cfg["hosts"]
  end

  test "a STABLEMATE_HOST with a port allows the bare host (port stripped for matching)" do
    cfg = boot_production("STABLEMATE_HOST" => "localhost:3000")
    # URL building keeps the full host:port…
    assert_equal "localhost:3000", cfg["mailer_host"]
    # …but host authorization matches the bare host (Rails strips the request port).
    assert_includes cfg["hosts"], "localhost"
    refute_includes cfg["hosts"], "localhost:3000"
  end
end
