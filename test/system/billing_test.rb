require "application_system_test_case"

# Hosted-tier billing, browser-driven (issue #19). We toggle the billing gate by
# stubbing the Stablemate Stripe keys (the in-process Capybara app sees the stub,
# exactly as ConfigGatedCapsTest toggles the #16 caps). Stripe itself is never
# hit: Checkout is stubbed and the plan is flipped the way production does it —
# through the verified-webhook sync on the user's Pay subscription mirror.
class BillingTest < ApplicationSystemTestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT
  PRO   = Stablemate::PRO_PLAN_MONITOR_LIMIT

  setup do
    @user = users(:alice)
    @user.monitors.delete_all
  end

  # Give the user an active Pro Pay subscription mirror (no Stripe API), then run
  # the same sync the verified webhook would — flipping plan to pro.
  def flip_to_pro_via_webhook!
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_sys_#{SecureRandom.hex(4)}")
    customer.subscriptions.create!(
      name: "pro", processor_id: "sub_sys_#{SecureRandom.hex(4)}",
      processor_plan: "price_pro", status: "active", quantity: 1
    )
    @user.sync_plan_from_subscription!
  end

  # (a) Free user at the limit sees Upgrade to Pro; after the webhook flips the
  # plan, the cap rises to 100 and the upgrade prompt is gone.
  test "free user hits the limit, upgrades, and the cap rises to Pro" do
    with_billing_enabled do
      @user.update!(plan: "free")
      FREE.times { |i| @user.monitors.create!(name: "M#{i}", **ATTRS) }

      sign_in @user
      assert_text "#{FREE} / #{FREE}"
      assert_selector "[data-testid='upgrade-button']"

      # The plan flips only via the verified webhook (Checkout itself is hosted).
      flip_to_pro_via_webhook!

      visit monitors_path
      assert_text "#{FREE} / #{PRO}"
      assert_no_selector "[data-testid='upgrade-button']"
      assert_link "New monitor"
    end
  end

  # (b) Pro user with more than the Free cap downgrades: the choose-5 UI forces an
  # exact selection; the rest become suspended.
  test "pro downgrade with too many monitors forces choosing five" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (FREE + 2).times.map { |i| @user.monitors.create!(name: "Keep#{i}", **ATTRS) }

      sign_in @user
      visit billing_subscription_path
      click_on "Downgrade to Free"

      # Submit is disabled until exactly FREE are chosen (choose_five Stimulus).
      assert_selector "[data-testid='confirm-downgrade'][disabled]"
      monitors.first(FREE).each { |m| find("input[type=checkbox][value='#{m.id}']").check }
      assert_selector "[data-testid='selection-counter']", text: "#{FREE} / #{FREE}"
      assert_no_selector "[data-testid='confirm-downgrade'][disabled]"

      click_on "Suspend the rest & downgrade"

      assert_current_path billing_subscription_path
      assert_equal 2, @user.monitors.where(status: "suspended").count
      assert_equal FREE, @user.monitors.counting_toward_cap.count

      # The dashboard now lists the suspended monitors in their own section.
      visit monitors_path
      assert_selector "[data-testid='suspended-section']"
      assert_text "#{FREE} / #{PRO}" # header counts active only
    end
  end

  # (c) Keyless self-host instance: no billing UI anywhere.
  test "keyless instance shows no billing UI" do
    with_billing_disabled do
      @user.update!(plan: "free")
      @user.monitors.create!(name: "Solo", **ATTRS)

      sign_in @user
      assert_no_selector "[data-testid='nav-billing']"

      # The billing path is an opaque 404 (no surface to probe).
      visit billing_subscription_path
      assert_no_selector "[data-testid='billing-panel']"
    end
  end
end
