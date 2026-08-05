require "test_helper"

# Upgrade checkout sub-resource (issue #19). End-to-end through the real Stripe
# SDK + Pay: we stub api.stripe.com at the HTTP boundary (WebMock) and assert we
# redirect the user to the hosted Checkout URL. No live network (test_helper locks
# it down); the genuine request/response code runs.
class Billing::CheckoutsControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  setup { @user = users(:bob) }

  # Fixed ids so the Stripe stubs and assert_requested matchers below can name the
  # same subscription; otherwise the shared helper (PaySubscriptionMirror).
  def give_pro_subscription!(status: "active")
    super(status: status, customer_id: "cus_test_123", subscription_id: "sub_test_123")
  end

  # WU-4 (H4) — an already-Pro user must not be able to open a second Checkout
  # (which Stripe would happily turn into a second subscription + double charge).
  test "an already-Pro user is bounced from checkout with no Stripe call" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        give_pro_subscription!
        sign_in @user

        post billing_checkout_path

        assert_redirected_to billing_subscription_path
        assert_equal "You're already on Pro.", flash[:alert]
        assert_not_requested :post, "https://api.stripe.com/v1/checkout/sessions"
      end
    end
  end

  # F5 — a `past_due` subscription is NOT active (Pay's active scope skips it) and
  # the plan has already dropped to Free by design, so the old guard let the user
  # subscribe a second time. Stripe's dunning retry on the first subscription can
  # still succeed later ⇒ two live Pro subscriptions, double billing.
  test "a past_due Pro subscription still blocks a second checkout" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        give_pro_subscription!(status: "past_due")
        sign_in @user

        post billing_checkout_path

        assert_redirected_to billing_subscription_path
        assert_equal "You're already on Pro.", flash[:alert]
        assert_not_requested :post, "https://api.stripe.com/v1/checkout/sessions"
      end
    end
  end

  # …but `incomplete` is NOT that case. It is a subscription whose very first
  # payment never completed (typically an abandoned or failed SCA challenge): it
  # has never billed, and Stripe expires it to incomplete_expired within ~24h. A
  # user in that state is someone actively trying to pay us — blocking their
  # retry with "You're already on Pro." is a certain lost upgrade, traded against
  # a double-billing risk that cannot occur (nothing has been charged, and the
  # stale attempt expires on its own).
  test "an incomplete Pro subscription does not block the user retrying checkout" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        give_pro_subscription!(status: "incomplete")
        sign_in @user

        stub_stripe_subscription_cancel("sub_test_123")
        url = stub_stripe_checkout_session
        post billing_checkout_path

        assert_redirected_to url
      end
    end
  end

  # …but letting them retry must not leave the abandoned attempt alive behind them.
  # Stripe gives the customer ~23h to authenticate that first invoice and emails
  # them a link straight to it, so "retry checkout, then complete the OLD invoice
  # from the email" would end in two active Pro subscriptions — the double billing
  # the guard exists to stop. Tear the dangling attempt down first; it has never
  # been charged, so cancelling it costs the user nothing.
  test "retrying checkout cancels the abandoned incomplete subscription first" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        give_pro_subscription!(status: "incomplete")
        sign_in @user

        stub_stripe_subscription_cancel("sub_test_123")
        stub_stripe_checkout_session
        post billing_checkout_path

        assert_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_test_123}
      end
    end
  end

  # The flip side: a genuinely finished subscription must not block a fresh one, or
  # a churned customer could never come back.
  test "a canceled Pro subscription does not block a new checkout" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        give_pro_subscription!(status: "canceled")
        sign_in @user

        url = stub_stripe_checkout_session
        post billing_checkout_path

        assert_redirected_to url
      end
    end
  end

  test "creating a checkout redirects to the Stripe hosted session" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        # Pre-seed a Stripe customer id so Pay skips customer creation; the session
        # create is the HTTP call we stub and assert the redirect from.
        @user.set_payment_processor(:stripe).update!(processor_id: "cus_test_123")
        sign_in @user

        url = stub_stripe_checkout_session
        post billing_checkout_path

        assert_redirected_to url
        assert_requested :post, "https://api.stripe.com/v1/checkout/sessions"
      end
    end
  end

  test "a Stripe failure surfaces a graceful retry alert, no redirect to Stripe" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, "price_pro_123") do
        @user.set_payment_processor(:stripe).update!(processor_id: "cus_test_123")
        sign_in @user

        stub_stripe_error(:post, "/v1/checkout/sessions")
        post billing_checkout_path

        assert_redirected_to billing_subscription_path
        assert_equal "Couldn't start checkout. Please try again.", flash[:alert]
      end
    end
  end

  test "without a configured price, it bails out with an alert (no Stripe call)" do
    with_billing_enabled do
      Stablemate.stub(:stripe_price_id_pro, nil) do
        sign_in @user
        post billing_checkout_path
        assert_redirected_to billing_subscription_path
        assert_equal "Pro plan isn't configured.", flash[:alert]
      end
    end
  end

  test "checkout is an opaque 404 when billing is disabled (self-host)" do
    with_billing_disabled do
      sign_in @user
      post billing_checkout_path
      assert_response :not_found
    end
  end

  test "checkout requires authentication" do
    with_billing_enabled do
      post billing_checkout_path
      assert_redirected_to new_session_path
    end
  end
end
