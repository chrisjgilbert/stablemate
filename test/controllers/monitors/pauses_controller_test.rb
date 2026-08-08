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

  # The show page hides both buttons for a monitor that is deliberately not
  # monitored, but the hidden button is not the guard. `paused` DOES count toward
  # the cap while `suspended` and `retired` do not, so pause-then-resume is a
  # round trip from "free" back to "monitored" that no cap check stands in the way
  # of — within_monitor_cap validates on: :create only. A plan-downgraded user
  # could walk every suspended monitor back to `up` on the Free plan.
  test "a monitor that occupies no cap slot cannot be paused or resumed" do
    sign_in @alice

    %w[suspended retired].each do |status|
      @monitor.update!(status:)

      post monitor_pause_path(@monitor)
      assert_response :not_found
      assert_equal status, @monitor.reload.status

      delete monitor_pause_path(@monitor)
      assert_response :not_found
      assert_equal status, @monitor.reload.status
    end
  end
end
