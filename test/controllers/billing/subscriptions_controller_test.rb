require "test_helper"

# Billing settings screen + config-gate (issue #19).
class Billing::SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:bob) }

  test "a free user sees the Upgrade to Pro affordance" do
    with_billing_enabled do
      @user.update!(plan: "free")
      sign_in @user
      get billing_subscription_path
      assert_response :ok
      assert_select "[data-testid='upgrade-button']"
      assert_select "[data-testid='downgrade-link']", false
      # The upgrade form must opt out of Turbo: it 303s to Stripe's cross-origin
      # Checkout, which Turbo would follow via fetch() and fail on CORS.
      assert_select %(form[action="#{billing_checkout_path}"][data-turbo="false"])
    end
  end

  test "a pro user sees portal and downgrade affordances" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      sign_in @user
      get billing_subscription_path
      assert_response :ok
      assert_select "[data-testid='downgrade-link']"
      assert_select "[data-testid='upgrade-button']", false
      # Same for the portal button — it 303s to Stripe's cross-origin Customer Portal.
      assert_select %(form[action="#{billing_portal_session_path}"][data-turbo="false"])
    end
  end

  # A past_due account reads Free (the plan drops by design while Stripe dunns),
  # so the page used to offer it the Upgrade button — which CheckoutsController
  # then bounced with "You're already on Pro.", because the subscription is very
  # much still live. Worse, the two affordances that DO work for that user, and
  # that they actually need — the portal, to fix the card — were hidden behind the
  # same plan check. The page has to ask the question the controller asks.
  test "a past_due user gets the portal and downgrade, not an upgrade that bounces" do
    with_billing_enabled do
      give_pro_subscription!(status: "past_due")
      @user.update!(plan: "free")
      sign_in @user

      get billing_subscription_path

      assert_response :ok
      assert_select "[data-testid='upgrade-button']", false,
        "an upgrade CheckoutsController will refuse must not be offered"
      assert_select "[data-testid='downgrade-link']"
      assert_select %(form[action="#{billing_portal_session_path}"][data-turbo="false"])
    end
  end

  # The first payment never completed, so nothing has been charged and Stripe
  # expires the attempt on its own. CheckoutsController deliberately lets that
  # user retry (UNBILLABLE_STATUSES), so the button must still be there.
  test "a user whose first payment never completed is still offered the upgrade" do
    with_billing_enabled do
      give_pro_subscription!(status: "incomplete")
      @user.update!(plan: "free")
      sign_in @user

      get billing_subscription_path

      assert_response :ok
      assert_select "[data-testid='upgrade-button']"
    end
  end

  test "billing settings is an opaque 404 when billing is disabled (self-host)" do
    with_billing_disabled do
      sign_in @user
      get billing_subscription_path
      assert_response :not_found
    end
  end
end
