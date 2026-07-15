require "application_system_test_case"

# Browser-driven involuntary-downgrade grace flow (projects.md §7/§12-J): after an
# over-cap drop to Free the banner is up (nothing suspended), the choose-N picker
# groups candidates by project, and committing a choice suspends the rest and
# clears the banner. CLAUDE.md: every user-facing flow ships a system test.
class DowngradeGraceTest < ApplicationSystemTestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  setup do
    @user = users(:alice)
    @project = @user.projects.sole
    @project.monitors.delete_all
    @second = @user.projects.create!(name: "Payments")
  end

  test "grace banner leads to the grouped picker and clears once a choice is made" do
    with_billing_enabled do
      # Pro user spread across two projects, over the Free cap; an involuntary drop
      # to Free opens the grace window (suspends nothing) and owes a choose-N.
      @user.update!(plan: "pro")
      first = FREE.times.map { |i| @project.monitors.create!(name: "First#{i}", **ATTRS) }
      2.times { |i| @second.monitors.create!(name: "Second#{i}", **ATTRS) }
      @user.sync_plan_from_subscription!
      assert @user.reload.must_choose_downgrade?

      sign_in @user

      # Banner is up on the dashboard; nothing suspended yet.
      assert_selector "[data-testid='downgrade-grace-banner']"
      assert_equal 0, @user.monitors.where(status: "suspended").count
      click_on "Choose monitors"

      # The picker groups candidates by project (both apps appear).
      assert_selector "[data-testid='downgrade-project-group']", count: 2
      assert_text "Payments"

      # Keep exactly FREE (all from the first project) and commit.
      first.each { |m| find("input[type=checkbox][value='#{m.id}']").check }
      assert_selector "[data-testid='selection-counter']", text: "#{FREE} / #{FREE}"
      click_on "Keep these & suspend the rest"

      # The rest are suspended, the lock is cleared, and the banner is gone.
      assert_equal FREE, @user.monitors.counting_toward_cap.count
      assert_equal 2, @user.monitors.where(status: "suspended").count
      refute @user.reload.awaiting_downgrade_choice?

      visit monitors_path
      assert_no_selector "[data-testid='downgrade-grace-banner']"
    end
  end
end
