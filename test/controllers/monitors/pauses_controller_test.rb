require "test_helper"

class Monitors::PausesControllerTest < ActionDispatch::IntegrationTest
  setup { @alice = users(:alice); @monitor = monitors(:up) }

  test "create pauses the monitor" do
    sign_in @alice
    post monitor_pause_path(@monitor)
    assert @monitor.reload.paused?
  end

  test "destroy resumes the monitor" do
    sign_in @alice
    @monitor.pause!
    delete monitor_pause_path(@monitor)
    assert @monitor.reload.up?
  end

  test "cannot pause another user's monitor" do
    sign_in @alice
    post monitor_pause_path(monitors(:bobs))
    assert_response :not_found
  end
end
