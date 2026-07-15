require "application_system_test_case"

# Issue #16 — caps are config-gated and default to OFF (the self-host default).
# These browser-driven tests prove both modes end to end:
#   - caps OFF: a 6th monitor creates with no at-limit UI; sign-up is always open
#     with no waitlist mode.
#   - caps ON: the at-limit monitor UI and the at-capacity → waitlist sign-up mode
#     still work (the managed-instance behaviour).
#
# We toggle the mode by stubbing the Stablemate cap constants the gate reads. The
# Capybara app runs in-process, so the stub is visible to the rendered request —
# this is the same mechanism LaunchHardeningTest already relies on.
class ConfigGatedCapsTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @project = @alice.projects.sole
    @project.monitors.delete_all # predictable count
  end

  # Caps OFF — a user creates a monitor past the old 5-limit with no at-limit UI.
  test "caps OFF: a sixth monitor creates successfully with no at-limit UI" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      6.times { |i| @project.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300) }
      sign_in @alice

      # No at-limit treatment, and the "New monitor" affordance is present.
      assert_no_selector "[data-testid='at-limit']"
      assert_no_selector "[data-testid='at-limit-note']"
      assert_link "New monitor"

      first(:link, "New monitor").click
      fill_in "Name", with: "Seventh monitor"
      find("select[aria-label='Expected interval preset']").select("Hourly")
      find("select[aria-label='Grace period preset']").select("5 minutes")
      click_on "Create monitor"

      assert_text "Seventh monitor"
      assert_equal 7, @alice.monitors.count
    end
  end

  # Caps OFF — sign-up is always open: the password fields render and there is no
  # waitlist form, even with more accounts than the managed cap would allow.
  test "caps OFF: sign-up is always open with no waitlist mode" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, 0) do
      visit sign_up_path

      assert_text "Create your account"
      assert_no_text "Join the waitlist"
      assert_selector "input[type=password]"
      assert_no_selector "[data-testid='waitlist-form']"

      assert_difference -> { User.count }, 1 do
        fill_in "Email", with: "open-signup@example.com"
        fill_in "Password", with: "password1234"
        fill_in "Confirm password", with: "password1234"
        click_on "Create account"
        assert_text "Welcome to Stablemate"
      end
    end
  end

  # Caps ON — the at-limit monitor UI still works (managed instance).
  test "caps ON: the dashboard shows the at-limit state at the configured cap" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 5) do
      5.times { |i| @project.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300) }
      sign_in @alice

      assert_text "5 / 5"
      assert_selector "[data-testid='at-limit']"
      refute_link "New monitor"
    end
  end

  # Caps ON — at capacity, the sign-up screen is in waitlist mode (managed instance).
  test "caps ON: at capacity the sign-up screen renders the waitlist" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      visit sign_up_path

      assert_text "Join the waitlist"
      assert_selector "input[type=email]"
      assert_no_selector "input[type=password]"
      assert_selector "[data-testid='waitlist-form']"
    end
  end
end
