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
