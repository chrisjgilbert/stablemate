require "test_helper"

# The gated choose-5 downgrade controller (issue #19, PRD §5.6).
class Billing::DowngradesControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  setup do
    @user = users(:bob)
    @user.monitors.delete_all
  end

  # A Pro user (cap 100) with n monitors — the realistic pre-downgrade state.
  def build_monitors(n)
    @user.update!(plan: "pro")
    n.times.map { |i| @user.monitors.create!(name: "M#{i}", **ATTRS) }
  end

  # Give the user a real active Pro subscription mirror so the downgrade actually
  # reaches Stripe to cancel (cancel_now!) — exercised end-to-end against a stub.
  def give_active_pro_subscription!(subscription_id: "sub_dg_123")
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_dg_123")
    customer.subscriptions.create!(
      name: "pro", processor_id: subscription_id,
      processor_plan: "price_pro", status: "active", quantity: 1
    )
    subscription_id
  end

  test "new renders the picker listing active monitors" do
    with_billing_enabled do
      build_monitors(FREE + 2)
      sign_in @user
      get new_billing_downgrade_path
      assert_response :ok
      assert_select "[data-testid='confirm-downgrade']"
    end
  end

  test "create with exactly five suspends the rest and redirects" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      sign_in @user
      post billing_downgrade_path, params: { keep_ids: monitors.first(FREE).map(&:id) }

      assert_redirected_to billing_subscription_path
      assert_equal FREE, @user.monitors.counting_toward_cap.count
      assert_equal 2, @user.monitors.where(status: "suspended").count
    end
  end

  test "create cancels the Stripe subscription end-to-end and suspends the rest" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      sub_id = give_active_pro_subscription!
      stub_stripe_subscription_cancel(sub_id)
      sign_in @user

      post billing_downgrade_path, params: { keep_ids: monitors.first(FREE).map(&:id) }

      assert_redirected_to billing_subscription_path
      # The real cancel_now! HTTP call was made to Stripe (the plan flip itself
      # arrives later by webhook — this only cancels and suspends).
      assert_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions/#{sub_id}}
      assert_equal FREE, @user.monitors.counting_toward_cap.count
      assert_equal 2, @user.monitors.where(status: "suspended").count
    end
  end

  test "a Stripe cancel failure leaves no monitor suspended (nothing half-done)" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      sub_id = give_active_pro_subscription!
      stub_stripe_error(:delete, "/v1/subscriptions/#{sub_id}", status: 500)
      sign_in @user

      post billing_downgrade_path, params: { keep_ids: monitors.first(FREE).map(&:id) }

      # Stripe is cancelled BEFORE any monitor is suspended (User::Downgrade#to_free!),
      # so a cancel failure must leave every monitor untouched.
      assert_response :service_unavailable
      assert_equal 0, @user.monitors.where(status: "suspended").count
    end
  end

  test "create with the wrong count re-renders unprocessable and suspends nothing" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      sign_in @user
      post billing_downgrade_path, params: { keep_ids: monitors.first(FREE - 1).map(&:id) }

      assert_response :unprocessable_entity
      assert_equal 0, @user.monitors.where(status: "suspended").count
    end
  end

  test "downgrade is an opaque 404 when billing is disabled" do
    with_billing_disabled do
      sign_in @user
      get new_billing_downgrade_path
      assert_response :not_found
    end
  end
end
