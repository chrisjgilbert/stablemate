require "minitest/mock"

# The config gates, toggled around a block.
#
# Billing, Slack and the Pro price id are all ENV/credentials-backed *methods* on
# Stablemate (see config/initializers/stablemate.rb), not constants — so a test
# that needs one on swaps the method for the duration of a block. That is what
# Object#stub is for; it is back in the bundle via the `minitest-mock` gem, which
# is where minitest 6 extracted it to. (Constants are Rails' own `stub_const`.)
#
# The fake credentials live here rather than on Stablemate itself: they are test
# fixtures, and the production module should not carry them.
#
# One constraint comes with Object#stub: a gate must not be nested inside itself
# (with_slack_disabled inside with_slack_enabled, say). Pick the value you want
# and use one block. #stub_gate below refuses the nesting rather than leaving you
# to discover it — see the comment there for what it would otherwise cost.
module TestCredentials
  # Never real keys — just enough for the config-gate and for the signature
  # verification the webhook tests do against a known secret.
  STRIPE_PUBLISHABLE_KEY = "pk_test_stablemate".freeze
  STRIPE_SECRET_KEY      = "sk_test_stablemate".freeze
  STRIPE_WEBHOOK_SECRET  = "whsec_stablemate_test".freeze
  SLACK_WEBHOOK_URL      = "https://hooks.slack.com/services/test".freeze
end

module ConfigGateTestHelper
  # Stub one method for the duration of a block, refusing to stub one that is
  # already stubbed.
  #
  # Object#stub saves the original under a fixed __minitest_stub__<name> alias, so
  # a second stub of the same method on the same object overwrites that saved copy
  # with the first stub. Unwinding then raises NameError and leaves the method
  # UNDEFINED for every test that follows in the worker — a failure that surfaces
  # far from its cause. The guard turns that into an immediate, explanatory error
  # while the method is still intact.
  def stub_gate(object, name, value, &block)
    if object.singleton_class.method_defined?(:"__minitest_stub__#{name}")
      raise ArgumentError, "#{object}.#{name} is already stubbed — " \
        "nesting a gate inside itself corrupts the saved original; use one block with the value you want"
    end

    object.stub(name, value, &block)
  end

  # Stub several methods on one object at once. Object#stub takes a single method,
  # and the billing gate needs four swapped together — nesting those by hand
  # reads worse than it deserves to.
  def stubbing(object, methods, &block)
    remaining = methods.to_a
    return yield if remaining.empty?

    name, value = remaining.first
    stub_gate(object, name, value) { stubbing(object, remaining.drop(1), &block) }
  end

  # Force an ENV var for the duration of a block, restoring it afterward. ENV is a
  # process global rather than an object with methods, so this is save/restore
  # rather than a stub; assigning nil is Ruby's own way of unsetting a key, which
  # is what restores an originally-unset variable.
  def with_env(name, value)
    original = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = original
  end
end

module BillingGateTestHelper
  include ConfigGateTestHelper # for #stubbing

  # In the test env there are no Stripe keys at boot, so Pay::Stripe.setup never
  # set ::Stripe.api_key. The HTTP-level tests drive the real SDK, which needs
  # one — so the api_key is assigned (it is a config attribute, not a method to
  # stub) and put back afterwards.
  def with_billing_enabled(&block)
    keys = {
      billing_enabled?: true,
      stripe_publishable_key: TestCredentials::STRIPE_PUBLISHABLE_KEY,
      stripe_secret_key: TestCredentials::STRIPE_SECRET_KEY,
      stripe_webhook_secret: TestCredentials::STRIPE_WEBHOOK_SECRET
    }
    original_api_key = ::Stripe.api_key
    ::Stripe.api_key = TestCredentials::STRIPE_SECRET_KEY

    stubbing(Stablemate, keys, &block)
  ensure
    ::Stripe.api_key = original_api_key
  end

  def with_billing_disabled(&block)
    stub_gate(Stablemate, :billing_enabled?, false, &block)
  end

  # Neutralise the only Pay handler step that would reach the Stripe API, so a
  # webhook can be processed end to end in tests without network. The test sets up
  # the Pay subscription mirror directly; in production this call keeps it fresh.
  def without_pay_stripe_network(&block)
    stub_gate(Pay::Stripe::Subscription, :sync, nil, &block)
  end
end

module SlackGateTestHelper
  include ConfigGateTestHelper # for #stub_gate

  # slack_notifications_enabled? is derived from the webhook URL, so swapping the
  # URL is what turns the gate on and off.
  def with_slack_enabled(&block)
    stub_gate(Stablemate, :slack_webhook_url, TestCredentials::SLACK_WEBHOOK_URL, &block)
  end

  def with_slack_disabled(&block)
    stub_gate(Stablemate, :slack_webhook_url, nil, &block)
  end
end

module CloudflareAnalyticsTestHelper
  include ConfigGateTestHelper # for #with_env

  # Force CLOUDFLARE_ANALYTICS_TOKEN for the duration of a block. nil disables it.
  def with_cloudflare_analytics_token(value, &block)
    with_env("CLOUDFLARE_ANALYTICS_TOKEN", value, &block)
  end
end
