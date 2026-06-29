require "test_helper"

class User::PlanTest < ActiveSupport::TestCase
  setup { @user = users(:bob); @user.monitors.delete_all }

  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  test "monitor_limit is the configured per-user cap" do
    assert_equal Stablemate::MAX_MONITORS_PER_USER, @user.monitor_limit
  end

  test "remaining_monitor_slots counts down, paused included, never negative" do
    assert_equal @user.monitor_limit, @user.remaining_monitor_slots

    @user.monitors.create!(name: "A", **ATTRS).pause!
    assert_equal @user.monitor_limit - 1, @user.reload.remaining_monitor_slots
  end

  test "at_monitor_cap? becomes true at the limit (paused count)" do
    refute @user.at_monitor_cap?
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @user.monitors.create!(name: "M#{i}", **ATTRS) }
    @user.monitors.first.pause!
    assert @user.reload.at_monitor_cap?
  end

  # Caps OFF (issue #16, self-host default): no per-user monitor cap.
  test "with the cap OFF, monitor_limit is nil and the cap is never reached" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      assert_nil @user.monitor_limit
      assert_equal Float::INFINITY, @user.remaining_monitor_slots

      (Stablemate::MAX_MONITORS_PER_USER.to_i + 6).times { |i| @user.monitors.create!(name: "M#{i}", **ATTRS) }
      refute @user.reload.at_monitor_cap?
      assert_equal Float::INFINITY, @user.reload.remaining_monitor_slots
    end
  end
end
