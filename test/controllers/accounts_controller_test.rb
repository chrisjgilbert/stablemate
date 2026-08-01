require "test_helper"

# The signed-in account page and the account-closure flow (launch-readiness §5 /
# WS-D). Deletion is irreversible and cancels money, so the surface it presents
# matters as much as the operation behind it: current password required, generic
# error on a mismatch, and a clean abort that deletes nothing if Stripe refuses.
class AccountsControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  setup do
    @user = users(:alice)
  end

  # Give the user a Stripe Pay::Customer with a live Pro subscription mirror.
  def make_pro!
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_#{SecureRandom.hex(6)}")
    customer.subscriptions.create!(
      name: "pro", processor_id: "sub_#{SecureRandom.hex(6)}",
      processor_plan: "price_pro", status: "active", quantity: 1
    )
  end

  test "anonymous users are redirected to sign in" do
    get account_path
    assert_redirected_to new_session_path
  end

  test "show renders the email address and the verified badge" do
    sign_in @user
    get account_path

    assert_response :success
    assert_match CGI.escapeHTML(@user.email_address), response.body
    assert_match "Verified", response.body
  end

  test "the authed header nav links to the account page" do
    sign_in @user
    get monitors_path

    assert_response :success
    assert_match "href=\"#{account_path}\"", response.body
  end

  test "show marks an unverified address as unverified" do
    @user.update!(verified_at: nil)
    sign_in @user
    get account_path

    assert_response :success
    assert_match "Unverified", response.body
  end

  test "show links to billing only when billing is enabled" do
    sign_in @user

    with_billing_enabled { get account_path }
    assert_match billing_subscription_path, response.body

    with_billing_disabled { get account_path }
    assert_no_match billing_subscription_path, response.body
  end

  test "destroy with the wrong password is a 422 and deletes nothing" do
    sign_in @user

    delete account_path, params: { current_password: "not-my-password" }

    assert_response :unprocessable_entity
    assert User.exists?(@user.id)
    # Generic — never confirm which half of the credential was wrong.
    assert_match "That password is incorrect.", response.body
  end

  test "destroy with a blank password is a 422 and deletes nothing" do
    sign_in @user

    delete account_path, params: { current_password: "" }

    assert_response :unprocessable_entity
    assert User.exists?(@user.id)
  end

  test "destroy with the correct password closes the account and signs the user out" do
    sign_in @user
    project = @user.projects.sole
    monitor = project.monitors.first
    api_key, = ApiKey.issue(project: project, name: "gem")

    with_billing_disabled do
      delete account_path, params: { current_password: "password1234" }
    end

    assert_redirected_to root_path
    assert_not User.exists?(@user.id)
    assert_not Project.exists?(project.id)
    assert_not Monitoring::Monitor.exists?(monitor.id)
    assert_not ApiKey.exists?(api_key.id)
    assert_equal 0, Session.where(user_id: @user.id).count

    # The cookie is gone too: a protected page now bounces to sign in.
    get monitors_path
    assert_redirected_to new_session_path
  end

  test "destroy takes the pay_* rows down with the account" do
    sign_in @user

    with_billing_enabled do
      subscription = make_pro!
      customer_id = subscription.customer_id
      stub_stripe_subscription_cancel(subscription.processor_id)

      delete account_path, params: { current_password: "password1234" }

      assert_redirected_to root_path
      assert_not Pay::Customer.exists?(customer_id), "orphaned pay_customers break later webhooks"
      assert_not Pay::Subscription.exists?(subscription.id)
    end
  end

  # Local/Stripe drift, or a Stripe outage: we would rather leave the account
  # completely intact and ask the user to retry than half-delete it.
  test "a Stripe cancel failure aborts the closure and deletes nothing" do
    sign_in @user

    with_billing_enabled do
      subscription = make_pro!
      stub_stripe_error(:delete, "/v1/subscriptions/#{subscription.processor_id}", status: 404)

      delete account_path, params: { current_password: "password1234" }

      assert_response :service_unavailable
      assert User.exists?(@user.id)
      assert Pay::Subscription.exists?(subscription.id)
      assert_match "couldn&#39;t cancel your subscription", response.body
    end
  end
end
