require "test_helper"

# The move-monitor sub-resource: PATCH /monitors/:monitor_id/project moves a
# manual monitor into another of the user's projects (projects.md §6). Tenant- and
# cross-project-scoped; gem monitors are rejected with a clear message.
class Monitors::ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @source = @alice.projects.sole
    @target = @alice.projects.create!(name: "Second app")
    @monitor = @source.monitors.create!(name: "Manual job",
      expected_interval_seconds: 3600, grace_period_seconds: 300, source: "manual")
    sign_in @alice
  end

  test "moves a manual monitor into another of the user's projects" do
    patch monitor_project_path(@monitor), params: { project_id: @target.id }
    assert_redirected_to @target
    assert_equal @target.id, @monitor.reload.project_id
  end

  test "refuses to move a gem monitor and keeps it put" do
    gem_monitor = monitors(:gem_synced)
    patch monitor_project_path(gem_monitor), params: { project_id: @target.id }

    assert_redirected_to gem_monitor
    assert_equal @source.id, gem_monitor.reload.project_id
    follow_redirect!
    assert_match(/gem/i, flash[:alert].to_s + @response.body)
  end

  test "cannot move another user's monitor" do
    patch monitor_project_path(monitors(:bobs)), params: { project_id: @target.id }
    assert_response :not_found
  end

  test "cannot move into another user's project" do
    bobs_project = users(:bob).projects.sole
    patch monitor_project_path(@monitor), params: { project_id: bobs_project.id }
    assert_response :not_found
    assert_equal @source.id, @monitor.reload.project_id
  end
end
