require "test_helper"

# Projects CRUD is tenant-scoped through current_user.projects: a foreign/unknown
# id is a 404 (opaque, no existence leak), never a cross-tenant read or write.
# (projects.md §6; CLAUDE.md — one cross-tenant test per CRUD slice.)
class ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @alices_project = @alice.projects.sole
    @bobs_project = @bob.projects.sole
  end

  test "anonymous users are redirected to sign in" do
    get projects_path
    assert_redirected_to new_session_path
  end

  test "index lists only the current user's projects" do
    sign_in @alice
    get projects_path

    assert_response :success
    assert_match CGI.escapeHTML(@alices_project.name), response.body
    refute_match CGI.escapeHTML(@bobs_project.name), response.body
  end

  test "index shows each project's monitor count, key count and created-ago" do
    sign_in @alice
    ApiKey.issue(project: @alices_project, name: "CI")
    get projects_path

    assert_response :success
    # Monitor count (existing) + key count (new) + a created-ago stamp per row.
    assert_match(/#{@alices_project.monitors.count} monitor/, response.body)
    assert_match(/#{@alices_project.api_keys.count} key/, response.body)
    assert_match(/ago/, response.body)
  end

  test "show renders the user's project and its monitors" do
    sign_in @alice
    get project_path(@alices_project)

    assert_response :success
    assert_match CGI.escapeHTML(@alices_project.name), response.body
    assert_match monitors(:up).name, response.body
  end

  test "a user cannot show another user's project (404, no leak)" do
    sign_in @alice
    get project_path(@bobs_project)
    assert_response :not_found
  end

  test "a user cannot edit another user's project" do
    sign_in @alice
    get edit_project_path(@bobs_project)
    assert_response :not_found
  end

  test "a user cannot update another user's project" do
    sign_in @alice
    patch project_path(@bobs_project), params: { project: { name: "hijacked" } }
    assert_response :not_found
    refute_equal "hijacked", @bobs_project.reload.name
  end

  test "a user cannot destroy another user's project" do
    sign_in @alice
    assert_no_difference -> { Project.count } do
      delete project_path(@bobs_project), params: { confirm_name: @bobs_project.name }
    end
    assert_response :not_found
  end

  test "create makes a project scoped to the current user" do
    sign_in @alice
    assert_difference -> { @alice.projects.count }, 1 do
      post projects_path, params: { project: { name: "New app" } }
    end
    project = @alice.projects.order(:created_at).last
    assert_equal "New app", project.name
    assert_redirected_to project_path(project)
  end

  test "create rejects a blank name" do
    sign_in @alice
    assert_no_difference -> { Project.count } do
      post projects_path, params: { project: { name: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "create after having no projects can return to new-monitor" do
    sign_in @alice
    @alice.projects.destroy_all

    post projects_path, params: { project: { name: "First app" }, after: "new_monitor" }
    assert_redirected_to new_monitor_path
  end

  test "update renames the project" do
    sign_in @alice
    patch project_path(@alices_project), params: { project: { name: "Renamed app" } }
    assert_redirected_to project_path(@alices_project)
    assert_equal "Renamed app", @alices_project.reload.name
  end

  test "destroy with the matching typed name deletes the project and its monitors" do
    sign_in @alice
    monitor_id = monitors(:up).id # capture before the cascade deletes the row
    assert_difference -> { Project.count }, -1 do
      delete project_path(@alices_project), params: { confirm_name: @alices_project.name }
    end
    assert_redirected_to projects_path
    refute Monitoring::Monitor.exists?(monitor_id) # cascaded
  end

  test "destroy without the matching typed name is rejected (belt-and-braces)" do
    sign_in @alice
    assert_no_difference -> { Project.count } do
      delete project_path(@alices_project), params: { confirm_name: "wrong name" }
    end
    assert_redirected_to edit_project_path(@alices_project)
  end
end
