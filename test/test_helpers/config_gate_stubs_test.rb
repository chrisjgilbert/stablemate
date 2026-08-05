require "test_helper"

# Every config-gate helper is a stub that must be put back — including when the
# block raises, or a failing test leaks its gate into every test that runs after it
# in the same worker. These pin that contract so the implementation underneath is
# free to change.
class ConfigGateStubsTest < ActiveSupport::TestCase
  test "Object#stub is available — minitest 6 extracted it to the minitest-mock gem" do
    assert_respond_to Stablemate, :stub,
      "minitest/mock is missing; the config-gate helpers below are meant to use it"
  end

  test "with_billing_enabled forces the gate and the keys it reads" do
    with_billing_enabled do
      assert Stablemate.billing_enabled?
      assert_equal TestCredentials::STRIPE_SECRET_KEY, Stablemate.stripe_secret_key
      assert_equal TestCredentials::STRIPE_SECRET_KEY, ::Stripe.api_key,
        "the real SDK needs an api_key while billing is forced on"
    end
  end

  test "with_billing_enabled restores every key it swapped, even when the block raises" do
    before = %i[billing_enabled? stripe_publishable_key stripe_secret_key stripe_webhook_secret]
      .to_h { |m| [ m, Stablemate.public_send(m) ] }
    before_api_key = ::Stripe.api_key

    assert_raises(RuntimeError) { with_billing_enabled { raise "boom" } }

    before.each { |method, value| assert_restored value, Stablemate.public_send(method), method }
    assert_restored before_api_key, ::Stripe.api_key, "::Stripe.api_key"
  end

  test "with_billing_disabled forces the gate off and restores it" do
    # billing_enabled? is already false in the test env, so comparing the value
    # afterwards proves nothing — a leaked stub reads identically. Compare the
    # method itself, which a leak would leave replaced.
    before = Stablemate.method(:billing_enabled?)

    with_billing_disabled { assert_not Stablemate.billing_enabled? }

    assert_raises(RuntimeError) { with_billing_disabled { raise "boom" } }
    assert_equal before, Stablemate.method(:billing_enabled?),
      "billing_enabled? leaked out of the stub block"
  end

  test "with_slack_enabled swaps the webhook URL and puts it back when the block raises" do
    before = Stablemate.slack_webhook_url

    with_slack_enabled do
      assert Stablemate.slack_notifications_enabled?
      assert_equal TestCredentials::SLACK_WEBHOOK_URL, Stablemate.slack_webhook_url
    end
    with_slack_disabled { assert_not Stablemate.slack_notifications_enabled? }
    assert_raises(RuntimeError) { with_slack_enabled { raise "boom" } }

    assert_restored before, Stablemate.slack_webhook_url, "slack_webhook_url"
  end

  test "the Pro price id can be swapped and comes back when the block raises" do
    before = Stablemate.stripe_price_id_pro

    Stablemate.stub(:stripe_price_id_pro, "price_from_the_test") do
      assert_equal "price_from_the_test", Stablemate.pro_price_id
    end
    assert_raises(RuntimeError) { Stablemate.stub(:stripe_price_id_pro, "x") { raise "boom" } }

    assert_restored before, Stablemate.stripe_price_id_pro, "stripe_price_id_pro"
  end

  test "with_cloudflare_analytics_token swaps the env var and puts it back when the block raises" do
    before = ENV["CLOUDFLARE_ANALYTICS_TOKEN"]

    with_cloudflare_analytics_token("tok_from_the_test") do
      assert_equal "tok_from_the_test", ENV["CLOUDFLARE_ANALYTICS_TOKEN"]
    end
    assert_raises(RuntimeError) { with_cloudflare_analytics_token("x") { raise "boom" } }

    assert_restored before, ENV["CLOUDFLARE_ANALYTICS_TOKEN"], "CLOUDFLARE_ANALYTICS_TOKEN"
  end

  test "without_pay_stripe_network neutralises the sync that would reach Stripe, then restores it" do
    before = Pay::Stripe::Subscription.method(:sync)

    without_pay_stripe_network { assert_nil Pay::Stripe::Subscription.sync("sub_x") }

    assert_equal before, Pay::Stripe::Subscription.method(:sync),
      "the real Pay sync must be back afterwards"
  end

  # Object#stub saves the original under a fixed __minitest_stub__<name> alias, so
  # stubbing the same method twice over corrupts that saved copy: the inner unwind
  # raises NameError and the method is left UNDEFINED for every test after it in
  # the worker. That is a mystifying way to find out, and the damage is done by
  # then — so the gates refuse the nesting up front instead.
  test "nesting the same gate is refused before it can corrupt the method" do
    error = assert_raises(ArgumentError) do
      with_slack_enabled { with_slack_disabled { flunk "the inner gate should not have opened" } }
    end

    assert_match(/slack_webhook_url/, error.message)
    assert_match(/already stubbed/, error.message)
    # The guard must fire BEFORE the method is damaged, so it still answers.
    assert_nothing_raised { Stablemate.slack_webhook_url }
  end

  private
    # Every gate here can legitimately be nil beforehand, and assert_equal refuses
    # nil — so name the verification once rather than scatter assert_nil branches.
    def assert_restored(expected, actual, what)
      return assert_nil actual, "#{what} leaked — it was unset and must be unset again" if expected.nil?

      assert_equal expected, actual, "#{what} leaked out of the stub block"
    end
end
