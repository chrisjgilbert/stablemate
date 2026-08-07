require "test_helper"

# Per-project ping-key management, mirroring the API-key controller (v1-scope §4).
# Issuance shows the raw sm_ping_… token once; revoke deletes it. Everything
# scopes through current_user.projects, so a foreign project or a key from
# another project is an opaque 404.
class Projects::PingKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @project = @alice.projects.sole
    sign_in @alice
  end

  test "create issues a key for the project and shows the raw token once" do
    assert_difference -> { @project.ping_keys.count }, 1 do
      post project_ping_keys_path(@project), params: { ping_key: { name: "Production" } }
    end
    assert_response :created
    assert_match(/sm_ping_[A-Za-z0-9]{32}/, response.body)
    assert_equal "Production", @project.ping_keys.order(:created_at).last.name
  end

  test "create defaults the name when none is given" do
    post project_ping_keys_path(@project)
    assert_response :created
    assert_equal "Ping key", @project.ping_keys.order(:created_at).last.name
  end

  # Rotation is add-before-remove, so a second live key is the supported state,
  # not an accident to guard against.
  test "a second key can be issued while the first is still live" do
    PingKey.issue(project: @project, name: "Production")

    assert_difference -> { @project.ping_keys.count }, 1 do
      post project_ping_keys_path(@project), params: { ping_key: { name: "Rotation" } }
    end
    assert_response :created
  end

  test "destroy revokes the key and redirects to the project" do
    key, = PingKey.issue(project: @project, name: "Production")
    assert_difference -> { @project.ping_keys.count }, -1 do
      delete project_ping_key_path(@project, key)
    end
    assert_redirected_to @project
  end

  test "cannot issue a key for another user's project" do
    bobs = users(:bob).projects.sole
    assert_no_difference -> { PingKey.count } do
      post project_ping_keys_path(bobs), params: { ping_key: { name: "x" } }
    end
    assert_response :not_found
  end

  test "cannot revoke a key from another user's project" do
    bobs = users(:bob).projects.sole
    foreign, = PingKey.issue(project: bobs, name: "Bobs")
    assert_no_difference -> { PingKey.count } do
      delete project_ping_key_path(bobs, foreign)
    end
    assert_response :not_found
  end

  # Cross-PROJECT (same tenant): a key belongs to one of the user's OWN projects,
  # but is addressed via a DIFFERENT project's path — must not be revocable there.
  test "cannot revoke a key through the wrong project of the same user" do
    other = @alice.projects.create!(name: "Other app")
    key, = PingKey.issue(project: @project, name: "Production")
    assert_no_difference -> { PingKey.count } do
      delete project_ping_key_path(other, key)
    end
    assert_response :not_found
    assert PingKey.exists?(key.id)
  end

  # The two credentials are separate tables precisely so neither surface can act
  # on the other's rows.
  test "an API key cannot be revoked through the ping-key route" do
    api_key, = ApiKey.issue(project: @project, name: "CI")

    assert_no_difference -> { ApiKey.count } do
      delete project_ping_key_path(@project, api_key)
    end
    assert_response :not_found
  end

  test "the project page shows a revoked key no more" do
    key, raw = PingKey.issue(project: @project, name: "Production")

    get project_path(@project)
    assert_response :success
    assert_match key.masked, response.body
    assert_no_match(/#{Regexp.escape(raw)}/, response.body)

    delete project_ping_key_path(@project, key)
    get project_path(@project)
    assert_no_match(/#{Regexp.escape(key.masked)}/, response.body)
  end
end
