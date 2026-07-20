require "test_helper"

class Monitors::PingTokensControllerTest < ActionDispatch::IntegrationTest
  setup { @alice = users(:alice); @monitor = monitors(:up) }

  # Scenario 12 — rotating changes the token and the old token 404s on ping.
  test "update rotates the token; the old token then 404s on ping" do
    sign_in @alice
    old_token = @monitor.ping_token

    patch monitor_ping_token_path(@monitor)
    @monitor.reload

    assert_not_equal old_token, @monitor.ping_token
    # Anchored so the (collapsed-by-default, once-pinged) ping-URL disclosure
    # opens back up with the freshly-rotated URL in view.
    assert_redirected_to monitor_path(@monitor, anchor: "ping-url-card")

    # The old ping URL is dead immediately.
    get ping_path(old_token)
    assert_response :not_found

    # The new one works.
    get ping_path(@monitor.ping_token)
    assert_response :success
  end

  test "cannot rotate another user's monitor token" do
    sign_in @alice
    patch monitor_ping_token_path(monitors(:bobs))
    assert_response :not_found
  end
end
