require "application_system_test_case"

# S1 (sign up → dashboard empty state) and S2 (sign in / sign out).
class AuthenticationTest < ApplicationSystemTestCase
  # S1 — sign up lands on the dashboard empty state with the gem-first snippet.
  test "S1: sign up lands on the dashboard empty state" do
    visit sign_up_path
    assert_text "Free — up to #{Stablemate::MAX_MONITORS_PER_USER} monitors"
    assert_link "Coming soon", href: sign_up_path

    fill_in "Email", with: "newdev@example.com"
    fill_in "Password", with: "password1234"
    fill_in "Confirm password", with: "password1234"
    click_on "Create account"

    # Signed-in users are redirected from the root to their dashboard (phase-4).
    assert_current_path monitors_path
    assert_text "Monitor your first cron job"
    assert_text "config/recurring.yml"
    assert_text "New monitor"

    # Pre-launch badge rides along in the authenticated header too, but as
    # plain text — a signed-in user never gets a sign-up CTA. (The pill is
    # styled uppercase via CSS, which the browser reflects in rendered text.)
    assert_text(/coming soon/i)
    assert_no_link "Coming soon"
  end

  # S2 — sign in returns to dashboard; sign out returns to sign in and protects routes.
  test "S2: sign in and sign out, protecting routes after sign out" do
    sign_in users(:alice)
    assert_text "Monitors"

    click_on "Sign out"
    assert_text "Sign in to Stablemate"
    assert_link "Coming soon", href: sign_up_path

    # Protected routes are unreachable once signed out.
    visit monitors_path
    assert_current_path new_session_path
  end
end
