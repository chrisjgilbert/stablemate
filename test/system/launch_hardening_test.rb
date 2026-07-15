require "application_system_test_case"

# S15 (at-capacity → waitlist) and S16 (at-limit monitor) — the phase-4
# Definition-of-Done system tests.
class LaunchHardeningTest < ApplicationSystemTestCase
  # S15 — at capacity, /sign_up renders waitlist mode (email field, NO password);
  # submitting shows the calm "on the list" success and creates no logged-in
  # session.
  test "S15: at capacity the sign-up screen is waitlist mode and creates no account" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      visit sign_up_path

      assert_text "Join the waitlist"
      assert_selector "input[type=email]"
      assert_no_selector "input[type=password]"

      assert_no_difference -> { User.count } do
        assert_difference -> { WaitlistSignup.count }, 1 do
          fill_in "Email", with: "waitlisted@example.com"
          click_on "Join the waitlist"
          assert_text "You're on the list"
        end
      end

      # No session was started — the authenticated header is absent and the
      # dashboard is still protected.
      assert_no_button "Sign out"
      visit monitors_path
      assert_current_path new_session_path
    end
  end

  # S16 — a user with the max monitors sees the at-limit treatment on the New
  # monitor action and "5 / 5" on the dashboard, with no upgrade/pricing UI.
  test "S16: at the monitor limit, the dashboard and New action show the at-limit state with no pricing UI" do
    alice = users(:alice)
    project = alice.projects.sole
    project.monitors.delete_all
    Stablemate::MAX_MONITORS_PER_USER.times do |i|
      project.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300)
    end

    sign_in alice
    limit = Stablemate::MAX_MONITORS_PER_USER

    # Dashboard: the count and the at-limit treatment (no "New monitor" link).
    assert_text "#{limit} / #{limit}"
    assert_selector "[data-testid='at-limit']"
    assert_selector "[data-testid='at-limit-note']"
    refute_link "New monitor"

    # No pricing/upgrade UI anywhere on the dashboard.
    assert_no_text(/upgrade/i)
    assert_no_text(/pricing/i)

    # The New-monitor action itself shows the matter-of-fact at-limit note (no form).
    visit new_monitor_path
    assert_selector "[data-testid='at-limit-note']"
    assert_text "You're at the #{limit}-monitor limit for the Free plan"
    assert_no_text(/upgrade/i)
    assert_no_text(/pricing/i)
  end
end
