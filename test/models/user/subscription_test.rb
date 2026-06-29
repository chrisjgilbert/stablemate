require "test_helper"

# User::Subscription concern (issue #19) — plan sync and the suspend/reactivate
# side effects. Pay is wrapped; we drive the mirror directly (no Stripe API).
class User::SubscriptionTest < ActiveSupport::TestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  setup do
    @user = users(:bob)
    @user.monitors.delete_all
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

  test "sync to free over the cap immediately suspends over-cap monitors" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @user.monitors.create!(name: "M#{i}", **ATTRS) }

      # No active Pro subscription ⇒ sync lands on free.
      @user.sync_plan_from_subscription!

      assert_equal "free", @user.reload.plan
      assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT, @user.monitors.counting_toward_cap.count
      assert_equal 2, @user.monitors.where(status: "suspended").count
      # Oldest kept.
      monitors.first(Stablemate::FREE_PLAN_MONITOR_LIMIT).each { |m| refute m.reload.suspended? }
    end
  end

  test "restore_suspended_monitors! reactivates only up to the available Pro slots" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      # 3 active + suspend 2 more than the Pro cap allows back.
      stub_const(Stablemate, :PRO_PLAN_MONITOR_LIMIT, 4) do
        active = 3.times.map { |i| @user.monitors.create!(name: "A#{i}", **ATTRS) }
        suspended = 3.times.map { |i| m = @user.monitors.create!(name: "S#{i}", **ATTRS); m.suspend!; m }

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
