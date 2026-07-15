require "test_helper"

# The gated "choose your 5" downgrade (PRD §5.6) — issue #19.
class User::DowngradeTest < ActiveSupport::TestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  setup do
    @user = users(:bob)
    @project = @user.projects.sole
    @project.monitors.delete_all
  end

  # Build n active monitors with the env cap OFF (so creation isn't blocked),
  # mirroring a Pro user who is dropping to Free.
  def build_monitors(n)
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      n.times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
    end
  end

  test "over the Free cap, a wrong-sized selection is rejected and nothing is suspended" do
    build_monitors(FREE + 3)

    [ [], @user.monitors.limit(FREE - 1).ids, @user.monitors.limit(FREE + 1).ids ].each do |bad|
      result = @user.downgrade_to_free!(keep_ids: bad)
      refute result.ok?
      assert_equal :must_choose, result.error
      assert_equal 0, @user.monitors.where(status: "suspended").count, "no suspension on a bad selection"
    end
  end

  test "over the Free cap, choosing exactly the cap suspends the rest and completes" do
    monitors = build_monitors(FREE + 3)
    keep = monitors.first(FREE).map(&:id)

    result = @user.downgrade_to_free!(keep_ids: keep)
    assert result.ok?

    assert_equal FREE, @user.monitors.counting_toward_cap.count
    assert_equal 3, @user.monitors.where(status: "suspended").count
    keep.each { |id| refute Monitoring::Monitor.find(id).suspended? }
  end

  test "at or under the Free cap, downgrade completes with no selection needed" do
    build_monitors(FREE - 1)
    result = @user.downgrade_to_free!(keep_ids: [])
    assert result.ok?
    assert_equal 0, @user.monitors.where(status: "suspended").count
  end

  test "enforce_free_cap! immediately suspends over-cap monitors keeping the oldest" do
    monitors = build_monitors(FREE + 2)

    User::Downgrade.new(@user).enforce_free_cap!

    assert_equal FREE, @user.monitors.counting_toward_cap.count
    # Oldest (first created) are kept.
    monitors.first(FREE).each { |m| refute m.reload.suspended? }
    monitors.last(2).each { |m| assert m.reload.suspended? }
  end

  test "enforce_free_cap! is a no-op when already within the cap" do
    build_monitors(FREE)
    assert_no_changes -> { @user.monitors.where(status: "suspended").count } do
      User::Downgrade.new(@user).enforce_free_cap!
    end
  end
end
