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
module TestCredentials
  # Never real keys — just enough for the config-gate and for the signature
  # verification the webhook tests do against a known secret.
  STRIPE_PUBLISHABLE_KEY = "pk_test_stablemate".freeze
  STRIPE_SECRET_KEY      = "sk_test_stablemate".freeze
  STRIPE_WEBHOOK_SECRET  = "whsec_stablemate_test".freeze
  SLACK_WEBHOOK_URL      = "https://hooks.slack.com/services/test".freeze
end

module ConfigGateTestHelper
  # Stub several methods on one object at once. Object#stub takes a single method,
  # and the billing gate needs four swapped together — nesting those by hand
  # reads worse than it deserves to.
  def stubbing(object, methods, &block)
    remaining = methods.to_a
    return yield if remaining.empty?

    name, value = remaining.first
    object.stub(name, value) { stubbing(object, remaining.drop(1), &block) }
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
    Stablemate.stub(:billing_enabled?, false, &block)
  end

  # Neutralise the only Pay handler step that would reach the Stripe API, so a
  # webhook can be processed end to end in tests without network. The test sets up
  # the Pay subscription mirror directly; in production this call keeps it fresh.
  def without_pay_stripe_network(&block)
    Pay::Stripe::Subscription.stub(:sync, nil, &block)
  end
end

module SlackGateTestHelper
  # slack_notifications_enabled? is derived from the webhook URL, so swapping the
  # URL is what turns the gate on and off.
  def with_slack_enabled(&block)
    Stablemate.stub(:slack_webhook_url, TestCredentials::SLACK_WEBHOOK_URL, &block)
  end

  def with_slack_disabled(&block)
    Stablemate.stub(:slack_webhook_url, nil, &block)
  end
end

module CloudflareAnalyticsTestHelper
  # Force CLOUDFLARE_ANALYTICS_TOKEN for the duration of a block. nil disables it.
  def with_cloudflare_analytics_token(value, &block)
    with_env("CLOUDFLARE_ANALYTICS_TOKEN", value, &block)
  end
end
