require "test_helper"

# Upgrade checkout sub-resource (issue #19). End-to-end through the real Stripe
# SDK + Pay: we stub api.stripe.com at the HTTP boundary (WebMock) and assert we
# redirect the user to the hosted Checkout URL. No live network (test_helper locks
# it down); the genuine request/response code runs.
class Billing::CheckoutsControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  setup { @user = users(:bob) }

  # Give the user an active Pro subscription in Pay's mirror so subscribed_to_pro?
  # is true (mirrors the downgrades test helper).
  def give_active_pro_subscription!
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_test_123")
    customer.subscriptions.create!(
      name: "pro", processor_id: "sub_test_123",
      processor_plan: "price_pro", status: "active", quantity: 1
    )
  end

  # WU-4 (H4) — an already-Pro user must not be able to open a second Checkout
  # (which Stripe would happily turn into a second subscription + double charge).
  test "an already-Pro user is bounced from checkout with no Stripe call" do
    with_billing_enabled do
      Stablemate.stub_price_id_pro("price_pro_123") do
        give_active_pro_subscription!
        sign_in @user

        post billing_checkout_path

        assert_redirected_to billing_subscription_path
        assert_equal "You're already on Pro.", flash[:alert]
        assert_not_requested :post, "https://api.stripe.com/v1/checkout/sessions"
      end
    end
  end

  test "creating a checkout redirects to the Stripe hosted session" do
    with_billing_enabled do
      Stablemate.stub_price_id_pro("price_pro_123") do
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
      Stablemate.stub_price_id_pro("price_pro_123") do
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
      Stablemate.stub_price_id_pro(nil) do
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
