require "test_helper"

# The Stripe SDK must not be eager-loaded into a keyless instance.
#
# stripe's railtie does `config.eager_load_namespaces << Stripe` unconditionally,
# so a production boot pulls in all ~1000 of its files — including on the
# self-host default, where `enabled_processors` is empty, the Billing:: routes
# 404, and no code path can reach a Stripe constant. Measured on a keyless
# production boot: ~350ms and ~34MB RSS for code that is never called.
#
# Both directions matter, so both are asserted. Dropping it when keys ARE present
# would be worse than the waste it saves: Stripe's resources are plain autoloads,
# so a forked Puma worker would resolve them lazily, per worker, instead of once
# pre-fork where copy-on-write shares the pages.
class StripeEagerLoadTest < ActiveSupport::TestCase
  include BootTestHelper

  # Eager loading only happens where it is switched on, so this has to be a
  # production boot — in test and development the namespace list is never consumed.
  PRODUCTION = { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "dummy" }.freeze

  STRIPE_KEYS = {
    "STRIPE_PUBLISHABLE_KEY" => "pk_test_boot",
    "STRIPE_SECRET_KEY" => "sk_test_boot",
    "STRIPE_WEBHOOK_SECRET" => "whsec_test_boot"
  }.freeze

  # Count real loaded files rather than inspecting the namespace list: this is the
  # cost we care about, and it stays true if the mechanism changes.
  SCRIPT = <<~RUBY.freeze
    puts({
      billing: Stablemate.billing_enabled?,
      stripe_files: $LOADED_FEATURES.count { |f| f.include?("/stripe-") }
    }.to_json)
  RUBY

  test "a keyless instance does not eager-load the Stripe SDK" do
    config = boot_app(SCRIPT, PRODUCTION)

    assert_equal false, config["billing"], "no keys ⇒ billing must be disabled"
    assert_operator config["stripe_files"], :<, 100,
      "a keyless production boot should not pull in the whole Stripe SDK"
  end

  test "a configured instance still eager-loads it, once, before Puma forks" do
    config = boot_app(SCRIPT, PRODUCTION.merge(STRIPE_KEYS))

    assert_equal true, config["billing"]
    assert_operator config["stripe_files"], :>, 500,
      "with keys present Stripe must still be eager-loaded pre-fork"
  end
end
