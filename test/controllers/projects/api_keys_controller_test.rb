require "test_helper"

# Per-project API-key management (projects.md §6/§12-E). Issuance shows the raw
# token once; revoke deletes it. Everything scopes through current_user.projects,
# so a foreign project or a key from another project is an opaque 404.
class Projects::ApiKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @project = @alice.projects.sole
    sign_in @alice
  end

  test "create issues a key for the project and shows the raw token once" do
    assert_difference -> { @project.api_keys.count }, 1 do
      post project_api_keys_path(@project), params: { api_key: { name: "Deploy" } }
    end
    assert_response :created
    assert_match(/sm_live_[A-Za-z0-9]{32}/, response.body)
    assert_equal "Deploy", @project.api_keys.order(:created_at).last.name
  end

  test "create defaults the name when none is given" do
    post project_api_keys_path(@project)
    assert_response :created
    assert_equal "API key", @project.api_keys.order(:created_at).last.name
  end

  test "destroy revokes the key and redirects to the project" do
    key, = ApiKey.issue(project: @project, name: "CI")
    assert_difference -> { @project.api_keys.count }, -1 do
      delete project_api_key_path(@project, key)
    end
    assert_redirected_to @project
  end

  test "cannot issue a key for another user's project" do
    bobs = users(:bob).projects.sole
    assert_no_difference -> { ApiKey.count } do
      post project_api_keys_path(bobs), params: { api_key: { name: "x" } }
    end
    assert_response :not_found
  end

  test "cannot revoke a key from another user's project" do
    bobs = users(:bob).projects.sole
    foreign, = ApiKey.issue(project: bobs, name: "Bobs")
    assert_no_difference -> { ApiKey.count } do
      delete project_api_key_path(bobs, foreign)
    end
    assert_response :not_found
  end

  # Cross-PROJECT (same tenant): a key belongs to one of the user's OWN projects,
  # but is addressed via a DIFFERENT project's path — must not be revocable there.
  test "cannot revoke a key through the wrong project of the same user" do
    other = @alice.projects.create!(name: "Other app")
    key, = ApiKey.issue(project: @project, name: "CI")
    assert_no_difference -> { ApiKey.count } do
      delete project_api_key_path(other, key)
    end
    assert_response :not_found
    assert ApiKey.exists?(key.id)
  end
end
