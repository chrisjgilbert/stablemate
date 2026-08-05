require "test_helper"

# The gated choose-5 downgrade controller (issue #19, PRD §5.6).
class Billing::DowngradesControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  setup do
    @user = users(:bob)
    @project = @user.projects.sole
    @project.monitors.delete_all
  end

  # A Pro user (cap 100) with n monitors — the realistic pre-downgrade state.
  def build_monitors(n)
    @user.update!(plan: "pro")
    n.times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
  end

  # Fixed ids, and the subscription's id returned: the downgrade actually reaches
  # Stripe to cancel (cancel_now!), so every test here has to stub and assert on
  # that same subscription.
  def pro_subscription_id!(subscription_id: "sub_dg_123", status: "active")
    give_pro_subscription!(status: status, customer_id: "cus_dg_123",
      subscription_id: subscription_id).processor_id
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
      sub_id = pro_subscription_id!
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

  # F5 — a card failure leaves the subscription `past_due` and the plan already on
  # Free. The user downgrading in-app to stop the dunning must actually reach
  # Stripe: with the old active-only lookup, cancel_pro_subscription! was a silent
  # no-op and Stripe kept retrying the invoice.
  test "the downgrade cancels a past_due subscription at Stripe" do
    with_billing_enabled do
      build_monitors(FREE - 2)
      @user.update!(plan: "free") # a failed payment already dropped the plan
      sub_id = pro_subscription_id!(status: "past_due")
      stub_stripe_subscription_cancel(sub_id)
      sign_in @user

      post billing_downgrade_path

      assert_redirected_to billing_subscription_path
      assert_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions/#{sub_id}}
    end
  end

  test "a Stripe cancel failure leaves no monitor suspended (nothing half-done)" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      sub_id = pro_subscription_id!
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

  # WU-5 (M4) — a Pro user at/under the Free cap gets a plain confirm, not the
  # un-submittable "pick exactly N" picker.
  test "new for a Pro user under the cap renders a confirm, not a picker" do
    with_billing_enabled do
      build_monitors(FREE - 2)
      sign_in @user
      get new_billing_downgrade_path

      assert_response :ok
      assert_select "input[type=checkbox][name='keep_ids[]']", count: 0
      assert_select "[data-testid='confirm-downgrade']"
    end
  end

  test "a Pro user under the cap downgrades via confirm, cancelling Stripe" do
    with_billing_enabled do
      build_monitors(FREE - 2)
      sub_id = pro_subscription_id!
      stub_stripe_subscription_cancel(sub_id)
      sign_in @user

      post billing_downgrade_path

      assert_redirected_to billing_subscription_path
      assert_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions/#{sub_id}}
      assert_equal 0, @user.monitors.where(status: "suspended").count
    end
  end

  # WU-6 (M5) — the involuntary choose-N lock lets the user re-pick from ALL their
  # monitors (incl. the auto-suspended ones) and resolves without touching Stripe.
  test "new in the involuntary lock lists all monitors including suspended" do
    with_billing_enabled do
      build_monitors(FREE + 2)
      @user.sync_plan_from_subscription! # ⇒ free, awaiting, oldest N kept
      assert @user.reload.must_choose_downgrade?
      sign_in @user

      get new_billing_downgrade_path

      assert_response :ok
      assert_select "input[type=checkbox][name='keep_ids[]']", count: FREE + 2
    end
  end

  test "resolving the involuntary lock re-picks without any Stripe call" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      @user.sync_plan_from_subscription!
      assert @user.reload.must_choose_downgrade?
      sign_in @user

      keep = monitors.last(FREE).map(&:id) # includes the auto-suspended ones
      post billing_downgrade_path, params: { keep_ids: keep }

      assert_redirected_to billing_subscription_path
      refute @user.reload.awaiting_downgrade_choice?
      assert_equal FREE, @user.monitors.counting_toward_cap.count
      assert_equal keep.sort, @user.monitors.counting_toward_cap.ids.sort
      assert_not_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions}
    end
  end

  # The picker groups candidates by project (projects.md §7) so the user sees which
  # app each monitor belongs to.
  test "the picker groups candidate monitors by project" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      second = @user.projects.create!(name: "Second app")
      3.times { |i| @project.monitors.create!(name: "A#{i}", **ATTRS) }
      FREE.times { |i| second.monitors.create!(name: "B#{i}", **ATTRS) }
      @user.sync_plan_from_subscription! # ⇒ free + awaiting (8 > FREE)
      assert @user.reload.must_choose_downgrade?
      sign_in @user

      get new_billing_downgrade_path

      assert_response :ok
      assert_select "[data-testid='downgrade-project-group']", 2
      assert_select "h2", text: @project.name
      assert_select "h2", text: "Second app"
    end
  end

  # M4 — a user who deletes monitors mid-grace lands here with the lock already
  # released (BaseController) and nothing left to do. The old confirm copy promised
  # to cancel a Pro subscription that was cancelled days ago, and offered a button
  # whose success notice claimed monitors had been suspended.
  test "an account already on Free is told there is nothing to downgrade" do
    with_billing_enabled do
      build_monitors(FREE - 2)
      @user.update!(plan: "free") # the involuntary drop already happened
      sign_in @user

      get new_billing_downgrade_path

      assert_response :ok
      assert_no_match(/subscription will be cancelled/, response.body)
      assert_match "already on the Free plan", response.body
      assert_select "[data-testid='confirm-downgrade']", false
    end
  end

  # …but "already gone" is only true when Stripe agrees. A card failure leaves the
  # subscription `past_due`: the plan has dropped to Free and the choose-N lock is
  # open, yet Stripe is still dunning. The picker tells that user their Pro
  # subscription will be cancelled, so committing the choice has to actually cancel
  # it — otherwise a dunning retry succeeds days later and they are billed for Pro
  # with monitors suspended, and this picker is their only in-app route out (the
  # billing page hides the Portal and Downgrade links once plan == free).
  test "resolving the involuntary choice cancels a subscription Stripe is still dunning" do
    with_billing_enabled do
      monitors = build_monitors(FREE + 2)
      sub_id = pro_subscription_id!(status: "past_due")
      @user.sync_plan_from_subscription! # ⇒ free + choose-N lock, nothing suspended
      assert @user.reload.must_choose_downgrade?
      stub_stripe_subscription_cancel(sub_id)
      sign_in @user

      post billing_downgrade_path, params: { keep_ids: monitors.first(FREE).map(&:id) }

      assert_redirected_to billing_subscription_path
      assert_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions/#{sub_id}}
      assert_equal FREE, @user.monitors.counting_toward_cap.count
      assert_equal 2, @user.monitors.where(status: "suspended").count
    end
  end

  # The involuntary picker is not a downgrade — the plan has already dropped and
  # (when Stripe agrees it is gone) all that's left is picking which N stay.
  test "the involuntary picker does not promise to cancel a subscription" do
    with_billing_enabled do
      build_monitors(FREE + 2)
      @user.sync_plan_from_subscription! # ⇒ free + choose-N lock
      assert @user.reload.must_choose_downgrade?
      sign_in @user

      get new_billing_downgrade_path

      assert_response :ok
      assert_no_match(/subscription will be cancelled/, response.body)
      assert_select "h1", text: "Choose monitors to keep"
    end
  end

  # …whereas a real Pro user leaving Pro is told exactly what happens to their
  # subscription.
  test "a voluntary over-cap downgrade says the subscription will be cancelled" do
    with_billing_enabled do
      build_monitors(FREE + 2)
      pro_subscription_id!
      sign_in @user

      get new_billing_downgrade_path

      assert_response :ok
      assert_match "subscription will be cancelled", response.body
      assert_select "h1", text: "Downgrade to Free"
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
