require "test_helper"

class Api::V1::Monitors::PingTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
    @project = @user.projects.sole
    _key, @raw = ApiKey.issue(project: @project, name: "CI")
    @monitor = monitors(:up) # in @project
  end

  def auth = { "Authorization" => "Bearer #{@raw}" }

  # Scenario 12 — rotate changes ping_token; old token -> 404 on ping.
  test "rotate changes the ping_token and returns the new ping_url" do
    old_token = @monitor.ping_token
    post rotate_api_v1_monitor_url(@monitor), headers: auth
    assert_response :success

    new_url = JSON.parse(response.body)["ping_url"]
    refute_equal old_token, @monitor.reload.ping_token
    assert new_url.include?(@monitor.ping_token)

    # Old token no longer pings.
    post ping_url(old_token)
    assert_response :not_found
  end

  test "rotate of a foreign monitor is 404" do
    post rotate_api_v1_monitor_url(monitors(:bobs)), headers: auth
    assert_response :not_found
  end

  test "rotate requires a bearer token" do
    post rotate_api_v1_monitor_url(@monitor)
    assert_response :unauthorized
  end
end
