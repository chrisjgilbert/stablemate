require "application_system_test_case"

# Issue #16 — caps are config-gated and default to OFF (the self-host default).
# These browser-driven tests prove both modes end to end:
#   - caps OFF: a 7th monitor registers past the old limit with no at-limit UI;
#     sign-up is always open with no waitlist mode.
#   - caps ON: the at-limit monitor UI and the at-capacity → waitlist sign-up mode
#     still work (the managed-instance behaviour).
#
# We toggle the mode by stubbing the Stablemate cap constants the gate reads. The
# Capybara app runs in-process, so the stub is visible to the rendered request —
# this is the same mechanism LaunchHardeningTest already relies on.
class ConfigGatedCapsTest < ApplicationSystemTestCase
  setup do
    # carol owns no monitors, so this file's counts are only what it creates.
    @user = users(:carol)
    @project = @user.projects.sole
  end

  # Was "a sixth monitor CREATES successfully": with config-as-code (v1-scope
  # §3.1) the only registrar is `stablemate:sync`, so the same property — no cap
  # means no refusal — is asserted through the sync path and read back off the
  # rendered dashboard.
  #
  # Driven over the real endpoint via browser_sync, not `project.sync_monitors`.
  # Capybara cannot set an Authorization header, but the Capybara server is a
  # real Puma on a real port — so the cap gate is asserted against
  # SyncsController, auth and response envelope included, rather than against
  # the model underneath it.
  test "caps OFF: a seventh monitor registers with no at-limit UI" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      6.times { |i| @project.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300) }
      api_key = ApiKey.issue(project: @project, name: "System test").last
      sign_in @user

      assert_no_selector "[data-testid='at-limit']"
      assert_no_selector "[data-testid='at-limit-note']"

      body = browser_sync(@project, api_key: api_key, monitors: [
        { registration_key: "seventh", name: "Seventh monitor",
          expected_interval_seconds: 3600, grace_period_seconds: 300 }
      ])
      assert_empty body["skipped"], "no cap is configured, so nothing may be refused"

      visit monitors_path
      assert_text "Seventh monitor"
      assert_equal 7, @user.monitors.count
      assert_no_selector "[data-testid='at-limit']"
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
      sign_in @user

      assert_text "5 / 5"
      assert_selector "[data-testid='at-limit']"
    end
  end

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
