require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup { @user = users(:alice) }

  test "name is required" do
    project = @user.projects.build(name: "")
    refute project.valid?
    assert_includes project.errors[:name], "can't be blank"
  end

  test "name is unique per user but may repeat across users" do
    @user.projects.create!(name: "Shared")
    dup = @user.projects.build(name: "Shared")
    refute dup.valid?

    # A different user may use the same name.
    assert users(:bob).projects.build(name: "Shared").valid?
  end

  test "destroying a project cascades to its monitors and their history" do
    project = @user.projects.create!(name: "Doomed")
    monitor = project.monitors.create!(name: "M", expected_interval_seconds: 3600, grace_period_seconds: 300)
    monitor.ping_events.create!(received_at: Time.current)

    assert_difference [ -> { Monitoring::Monitor.count }, -> { PingEvent.count } ], -1 do
      project.destroy
    end
  end

  test "a user may delete down to zero projects" do
    @user.projects.destroy_all
    assert_equal 0, @user.reload.projects.count
    assert_equal 0, @user.monitors.count
  end
end
