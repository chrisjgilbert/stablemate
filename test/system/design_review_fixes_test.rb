require "application_system_test_case"

# Browser-driven Definition-of-Done gates for the design-review remediation
# (docs/specs/design-review-fixes.md §4). One robust flow per work unit.
class DesignReviewFixesTest < ApplicationSystemTestCase
  include StripeApiStubs

  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  setup { @alice = users(:alice); @project = @alice.projects.sole }

  def give_active_pro_subscription!(sub_id)
    customer = @alice.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_sys_#{SecureRandom.hex(4)}")
    customer.subscriptions.create!(
      name: "pro", processor_id: sub_id,
      processor_plan: "price_pro", status: "active", quantity: 1
    )
  end

  # S-DR1 (WU-2, H1) — pausing a DOWN monitor clears its incident, and after a
  # ping + resume the badge returns to Up with no lingering "down" banner. This is
  # the flow that previously stranded an open incident behind an "up" badge.
  test "S-DR1: pausing a down monitor clears the incident and resume returns it to up" do
    monitor = @project.monitors.create!(
      name: "Flaky job", expected_interval_seconds: 3600, grace_period_seconds: 300,
      status: "up", last_ping_at: 2.hours.ago, next_due_at: 90.minutes.ago
    )
    monitor.flag_missed! # overdue -> down, opens the incident + banner

    sign_in @alice
    visit monitor_path(monitor)
    assert_selector "[data-testid='incident-banner']"

    # Pause resolves the open incident, so the banner disappears immediately.
    click_on "Pause"
    assert_text "Paused"
    assert_no_selector "[data-testid='incident-banner']"

    # The job's cron keeps firing while paused (a machine ping, not a UI action).
    monitor.check_in!(received_at: Time.current)

    click_on "Resume"
    assert_no_text "Paused"
    assert_no_selector "[data-testid='incident-banner']"
    assert_selector "##{dom_id(monitor, :badge)}", text: "Up"
  end

  # S-DR2 (WU-5, M4) — a Pro user UNDER the Free cap downgrades through a plain
  # confirm (no un-submittable "pick exactly N" picker).
  test "S-DR2: a small Pro account downgrades via a confirm, not the picker" do
    with_billing_enabled do
      @alice.update!(plan: "pro")
      @project.monitors.delete_all
      (FREE - 2).times { |i| @project.monitors.create!(name: "Small#{i}", **ATTRS) }
      sub_id = "sub_sys_#{SecureRandom.hex(4)}"
      give_active_pro_subscription!(sub_id)
      stub_stripe_subscription_cancel(sub_id)

      sign_in @alice
      visit billing_subscription_path
      click_on "Downgrade to Free"

      # Confirm mode: no checkboxes, a single enabled button.
      assert_no_selector "input[type=checkbox][name='keep_ids[]']"
      find("[data-testid='confirm-downgrade']").click

      assert_current_path billing_subscription_path
      assert_requested :delete, %r{https://api\.stripe\.com/v1/subscriptions/#{sub_id}}
    end
  end

  # S-DR3 (WU-6, M5) — after an involuntary drop to Free over the cap, the Billing
  # page shows the choose-N lock; the picker lists ALL monitors (incl. the
  # auto-suspended ones) and confirming re-picks which N stay active.
  test "S-DR3: the involuntary choose-N lock lets the user re-pick which to keep" do
    with_billing_enabled do
      @alice.update!(plan: "pro")
      @project.monitors.delete_all
      monitors = (FREE + 2).times.map { |i| @project.monitors.create!(name: "Job#{i}", **ATTRS) }
      # No active Pro subscription mirror ⇒ the sync drops to Free involuntarily.
      @alice.sync_plan_from_subscription!
      assert @alice.reload.must_choose_downgrade?

      sign_in @alice
      visit billing_subscription_path
      assert_selector "[data-testid='choose-five-lock']"
      click_on "Choose which #{FREE} to keep active"

      # The picker lists every monitor, including the two auto-suspended ones.
      assert_selector "input[type=checkbox][name='keep_ids[]']", count: FREE + 2
      monitors.last(FREE).each { |m| find("input[type=checkbox][value='#{m.id}']").check }
      click_on "Keep these & suspend the rest"

      assert_current_path billing_subscription_path
      refute @alice.reload.awaiting_downgrade_choice?
      assert_equal monitors.last(FREE).map(&:id).sort, @alice.monitors.counting_toward_cap.ids.sort
    end
  end
end
