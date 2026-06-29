require "test_helper"

# Upgrade checkout sub-resource (issue #19). We stub Stripe's Checkout::Session
# at the boundary (no network) and assert we redirect the user to its hosted URL.
class Billing::CheckoutsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:bob) }

  # Stub the Stripe SDK call Pay makes so checkout returns a fake hosted session.
  def stub_stripe_checkout(url: "https://checkout.stripe.test/session")
    original = ::Stripe::Checkout::Session.method(:create)
    ::Stripe::Checkout::Session.define_singleton_method(:create) do |*, **|
      ::Stripe::Checkout::Session.construct_from(id: "cs_test", url: url)
    end
    yield url
  ensure
    ::Stripe::Checkout::Session.define_singleton_method(:create, original)
  end

  test "creating a checkout redirects to the Stripe hosted session" do
    with_billing_enabled do
      stub_const(Stablemate, :STRIPE_PRICE_ID_PRO, "price_pro_123") do
        # Pre-seed a Stripe customer with a processor_id so Pay's checkout skips
        # the customer-create API call (api_record). The session create itself is
        # stubbed below.
        @user.set_payment_processor(:stripe).update!(processor_id: "cus_test_123")
        sign_in @user
        stub_stripe_checkout do |url|
          post billing_checkout_path
          assert_redirected_to url
        end
      end
    end
  end

  test "without a configured price, it bails out with an alert (no Stripe call)" do
    with_billing_enabled do
      stub_const(Stablemate, :STRIPE_PRICE_ID_PRO, nil) do
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
