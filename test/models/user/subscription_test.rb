require "test_helper"

# User::Subscription concern (issue #19) — plan sync and the suspend/reactivate
# side effects. Pay is wrapped; we drive the mirror directly (no Stripe API).
class User::SubscriptionTest < ActiveSupport::TestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  setup do
    @user = users(:bob)
    @project = @user.projects.sole
    @project.monitors.delete_all
  end

  def give_active_pro!
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_#{SecureRandom.hex(4)}")
    customer.subscriptions.create!(
      name: "pro", processor_id: "sub_#{SecureRandom.hex(4)}",
      processor_plan: "price_pro", status: "active", quantity: 1
    )
  end

  test "subscribed_to_pro? reflects the active Pay subscription mirror" do
    with_billing_enabled do
      refute @user.subscribed_to_pro?
      give_active_pro!
      assert @user.reload.subscribed_to_pro?
    end
  end

  # §12-J — an involuntary over-cap drop to Free starts a GRACE window and suspends
  # NOTHING: every monitor keeps running while the user is asked to pick their N. A
  # payment blip must never silently stop monitoring.
  test "sync to free over the cap starts a grace window and suspends nothing" do
    with_billing_enabled do
      freeze_time do
        @user.update!(plan: "pro")
        monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

        # No active Pro subscription ⇒ sync lands on free.
        @user.sync_plan_from_subscription!
        @user.reload

        assert_equal "free", @user.plan
        # Nothing suspended — all monitors still count during the window.
        assert_equal 0, @user.monitors.where(status: "suspended").count
        assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT + 2, @user.monitors.counting_toward_cap.count
        monitors.each { |m| refute m.reload.suspended? }

        # A choose-N decision is owed by the deadline.
        assert @user.awaiting_downgrade_choice?
        assert_in_delta Stablemate::DOWNGRADE_GRACE_PERIOD.from_now, @user.downgrade_choice_deadline_at, 1.second
      end
    end
  end

  # WU-6 (M5) / §12-J — an involuntary drop to Free over the cap locks the account
  # into a choose-N decision (a real flag + deadline), not silently keeping the
  # oldest N with no recourse. During grace nothing is suspended.
  test "an involuntary drop to free over the cap locks the account into a choose-N decision" do
    with_billing_enabled do
      freeze_time do
        @user.update!(plan: "pro")
        (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

        @user.sync_plan_from_subscription! # no active sub ⇒ free
        @user.reload

        assert @user.awaiting_downgrade_choice?
        assert @user.must_choose_downgrade?
        assert_in_delta Stablemate::DOWNGRADE_GRACE_PERIOD.from_now, @user.downgrade_choice_deadline_at, 1.second
        # Grace: every monitor still counts — none suspended during the window.
        assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT + 2, @user.monitors.counting_toward_cap.count
      end
    end
  end

  # A repeat cancel webhook while already awaiting must NOT push the deadline out —
  # the user gets one fixed window, not a rolling one.
  test "a repeat free sync does not extend the grace deadline" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

      @user.sync_plan_from_subscription!
      first_deadline = @user.reload.downgrade_choice_deadline_at

      travel 2.days do
        @user.sync_plan_from_subscription! # a later webhook, still over-cap on Free
      end

      assert_equal first_deadline, @user.reload.downgrade_choice_deadline_at
    end
  end

  test "re-upgrading to pro clears the choose-N lock and its deadline" do
    with_billing_enabled do
      @user.update!(plan: "free", awaiting_downgrade_choice: true, downgrade_choice_deadline_at: 3.days.from_now)
      give_active_pro!

      @user.sync_plan_from_subscription! # active sub ⇒ pro

      assert_equal "pro", @user.reload.plan
      refute @user.awaiting_downgrade_choice?
      refute @user.must_choose_downgrade?
      assert_nil @user.downgrade_choice_deadline_at
    end
  end

  test "resolve_downgrade_choice! reactivates the chosen, suspends the rest, clears the lock" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      @user.sync_plan_from_subscription! # ⇒ free, awaiting, grace (nothing suspended)
      assert @user.reload.must_choose_downgrade?

      # Re-pick the LAST N — during grace all are active; resolve suspends the rest.
      keep = monitors.last(Stablemate::FREE_PLAN_MONITOR_LIMIT).map(&:id)
      result = @user.resolve_downgrade_choice!(keep_ids: keep)

      assert result.ok?
      refute @user.reload.awaiting_downgrade_choice?
      assert_nil @user.downgrade_choice_deadline_at
      assert_equal keep.sort, @user.monitors.counting_toward_cap.ids.sort
      assert_equal 2, @user.monitors.where(status: "suspended").count
    end
  end

  test "resolve_downgrade_choice! with the wrong count is rejected and keeps the lock" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      @user.sync_plan_from_subscription!

      result = @user.resolve_downgrade_choice!(keep_ids: [ monitors.first.id ]) # too few

      refute result.ok?
      assert @user.reload.awaiting_downgrade_choice?
    end
  end

  # WU-6 review follow-up — a locked user who deletes monitors back within the Free
  # cap must not be stranded: the lock lifts and the survivors reactivate.
  test "the choose-N lock releases when the account drops back within the Free cap" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      @user.sync_plan_from_subscription! # locked, grace (nothing suspended)
      assert @user.reload.must_choose_downgrade?

      # Delete active monitors until the total fits under the Free cap.
      @user.monitors.counting_toward_cap.order(:created_at).limit(3).each(&:destroy)

      @user.release_downgrade_lock_if_within_cap!

      refute @user.reload.awaiting_downgrade_choice?
      refute @user.must_choose_downgrade?
      assert_nil @user.downgrade_choice_deadline_at
      assert_equal 0, @user.monitors.where(status: "suspended").count
    end
  end

  test "restore_suspended_monitors! reactivates only up to the available Pro slots" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      # 3 active + suspend 2 more than the Pro cap allows back.
      stub_const(Stablemate, :PRO_PLAN_MONITOR_LIMIT, 4) do
        active = 3.times.map { |i| @project.monitors.create!(name: "A#{i}", **ATTRS) }
        suspended = 3.times.map { |i| m = @project.monitors.create!(name: "S#{i}", **ATTRS); m.suspend!; m }

        @user.restore_suspended_monitors!

        # Only one slot free (4 cap - 3 active) ⇒ exactly one reactivated.
        assert_equal 4, @user.monitors.counting_toward_cap.count
        assert_equal 2, @user.monitors.where(status: "suspended").count
        assert active.all? { |m| !m.reload.suspended? }
        # The oldest suspended is the one restored.
        refute suspended.first.reload.suspended?
      end
    end
  end
end
