require "test_helper"

# Customer Portal sub-resource (issue #19). End-to-end through the real Stripe SDK
# + Pay against a stubbed api.stripe.com: creating a portal session redirects the
# user to Stripe's hosted portal. No live network (test_helper locks it down).
class Billing::PortalSessionsControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  setup { @user = users(:bob) }

  test "opening the portal redirects to the Stripe hosted portal session" do
    with_billing_enabled do
      @user.set_payment_processor(:stripe).update!(processor_id: "cus_test_123")
      sign_in @user

      url = stub_stripe_portal_session
      post billing_portal_session_path

      assert_redirected_to url
      assert_requested :post, "https://api.stripe.com/v1/billing_portal/sessions"
    end
  end

  test "a Stripe failure surfaces a graceful retry alert, no redirect to Stripe" do
    with_billing_enabled do
      @user.set_payment_processor(:stripe).update!(processor_id: "cus_test_123")
      sign_in @user

      stub_stripe_error(:post, "/v1/billing_portal/sessions")
      post billing_portal_session_path

      assert_redirected_to billing_subscription_path
      assert_equal "Couldn't open the billing portal. Please try again.", flash[:alert]
    end
  end

  test "the portal is an opaque 404 when billing is disabled (self-host)" do
    with_billing_disabled do
      sign_in @user
      post billing_portal_session_path
      assert_response :not_found
    end
  end

  test "the portal requires authentication" do
    with_billing_enabled do
      post billing_portal_session_path
      assert_redirected_to new_session_path
    end
  end
end
