require "test_helper"

class User::PlanTest < ActiveSupport::TestCase
  setup { @user = users(:bob); @project = @user.projects.sole; @project.monitors.delete_all }

  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  test "monitor_limit is the configured per-user cap" do
    assert_equal Stablemate::MAX_MONITORS_PER_USER, @user.monitor_limit
  end

  test "remaining_monitor_slots counts down, paused included, never negative" do
    assert_equal @user.monitor_limit, @user.remaining_monitor_slots

    @project.monitors.create!(name: "A", **ATTRS).pause!
    assert_equal @user.monitor_limit - 1, @user.reload.remaining_monitor_slots
  end

  test "at_monitor_cap? becomes true at the limit (paused count)" do
    refute @user.at_monitor_cap?
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
    @user.monitors.first.pause!
    assert @user.reload.at_monitor_cap?
  end

  # Caps OFF (issue #16, self-host default): no per-user monitor cap.
  test "with the cap OFF, monitor_limit is nil and the cap is never reached" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      assert_nil @user.monitor_limit
      assert_equal Float::INFINITY, @user.remaining_monitor_slots

      (Stablemate::MAX_MONITORS_PER_USER.to_i + 6).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      refute @user.reload.at_monitor_cap?
      assert_equal Float::INFINITY, @user.reload.remaining_monitor_slots
    end
  end

  # Suspended monitors don't occupy a cap slot (PRD §3.3) — distinct from paused.
  test "suspended monitors are excluded from the cap count" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 2) do
      a = @project.monitors.create!(name: "A", **ATTRS)
      @project.monitors.create!(name: "B", **ATTRS)
      assert @user.reload.at_monitor_cap?

      a.suspend!
      refute @user.reload.at_monitor_cap?
      assert_equal 1, @user.remaining_monitor_slots
    end
  end

  # Billing ON (managed instance): the cap is plan-derived, not env-driven.
  test "with billing ENABLED, free users get the Free cap and pro users the Pro cap" do
    with_billing_enabled do
      @user.update!(plan: "free")
      assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT, @user.monitor_limit

      @user.update!(plan: "pro")
      assert_equal Stablemate::PRO_PLAN_MONITOR_LIMIT, @user.monitor_limit
    end
  end

  # Billing ON wins over the env cap (the env cap is the self-host-only knob).
  test "with billing ENABLED, the plan cap overrides the env cap" do
    with_billing_enabled do
      stub_const(Stablemate, :MAX_MONITORS_PER_USER, 999) do
        @user.update!(plan: "free")
        assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT, @user.monitor_limit
      end
    end
  end

  # over_free_cap_by drives the choose-5 downgrade. (Build past the Free cap with
  # the env cap OFF so creation isn't blocked — mirrors a Pro user dropping to Free.)
  test "over_free_cap_by counts active monitors past the Free cap" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      (Stablemate::FREE_PLAN_MONITOR_LIMIT + 3).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      assert_equal 3, @user.over_free_cap_by

      @user.monitors.first.suspend!
      assert_equal 2, @user.reload.over_free_cap_by
    end
  end
end
