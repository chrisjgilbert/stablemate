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
end
