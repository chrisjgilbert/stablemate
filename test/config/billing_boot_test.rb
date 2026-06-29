require "test_helper"
require "open3"

# The hosted-tier billing config-gate (issue #19) only does anything at BOOT: the
# pay.rb initializer registers the Stripe processor and feeds Pay its keys when
# Stablemate.billing_enabled?. The rest of the suite toggles the gate at runtime
# (stub_billing) and so never re-runs that initializer with real keys — which means
# a broken initializer (e.g. calling a Pay setter that doesn't exist) would crash
# the managed instance on boot while every other test stayed green.
#
# These tests close that gap by booting a throwaway process with the Stripe env set
# (and unset) and reading the resulting config back out — the managed instance must
# actually boot, and the keyless self-host instance must stay dormant.
class BillingBootTest < ActiveSupport::TestCase
  STRIPE_ENV = {
    "STRIPE_PUBLISHABLE_KEY" => "pk_test_boot",
    "STRIPE_SECRET_KEY" => "sk_test_boot",
    "STRIPE_WEBHOOK_SECRET" => "whsec_test_boot"
  }.freeze

  def boot(env)
    script = <<~RUBY
      puts({
        billing_enabled: Stablemate.billing_enabled?,
        processors: Pay.enabled_processors,
        stripe_api_key_present: ::Stripe.api_key.present?
      }.to_json)
    RUBY
    out, err, status = Open3.capture3(
      { "RAILS_ENV" => "test" }.merge(env),
      "bin/rails", "runner", script, chdir: Rails.root.to_s
    )
    assert status.success?, "app failed to boot with env #{env.keys.inspect}: #{err}"
    JSON.parse(out.lines.last)
  end

  test "the managed instance boots with Stripe keys set and enables billing" do
    cfg = boot(STRIPE_ENV)

    assert_equal true, cfg["billing_enabled"]
    assert_includes cfg["processors"], "stripe"
    # pay.rb must bridge our keys onto the names Pay reads so Pay::Stripe.setup can
    # set ::Stripe.api_key — the bug this test guards against left it unset/crashed.
    assert_equal true, cfg["stripe_api_key_present"]
  end

  test "the keyless self-host instance boots with billing dormant" do
    cfg = boot(
      "STRIPE_PUBLISHABLE_KEY" => nil,
      "STRIPE_SECRET_KEY" => nil,
      "STRIPE_WEBHOOK_SECRET" => nil
    )

    assert_equal false, cfg["billing_enabled"]
    assert_empty cfg["processors"]
  end
end
