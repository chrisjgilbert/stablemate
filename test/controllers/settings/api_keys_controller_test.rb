require "test_helper"

class Settings::ApiKeysControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:alice) }

  test "index requires authentication" do
    delete session_path # sign out
    get settings_api_keys_url
    assert_redirected_to new_session_path
  end

  test "index lists the user's keys masked" do
    key, raw = ApiKey.issue(user: users(:alice), name: "CI")
    get settings_api_keys_url
    assert_response :success
    assert_includes response.body, key.masked
    refute_includes response.body, raw # raw never re-rendered
  end

  test "create issues a key and shows the raw token once" do
    assert_difference -> { users(:alice).api_keys.count }, 1 do
      post settings_api_keys_url, params: { api_key: { name: "Deploy" } }
    end
    assert_response :created
    body = response.body
    assert_match(/sm_live_[A-Za-z0-9]{32}/, body)
  end

  test "destroy revokes the key" do
    key, = ApiKey.issue(user: users(:alice), name: "CI")
    assert_difference -> { users(:alice).api_keys.count }, -1 do
      delete settings_api_key_url(key)
    end
    assert_redirected_to settings_api_keys_path
  end

  test "cannot revoke another user's key" do
    foreign, = ApiKey.issue(user: users(:bob), name: "Bobs")
    assert_no_difference -> { ApiKey.count } do
      delete settings_api_key_url(foreign)
    end
    assert_response :not_found
  end
end
