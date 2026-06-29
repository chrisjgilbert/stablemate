require "application_system_test_case"

# Email verification flow (S20) — browser-driven. Clicking the link is simulated
# by generating the token from the user record and visiting the path directly,
# exactly as the link in the verification email would do.
class EmailVerificationTest < ApplicationSystemTestCase
  # S20 — sign up, follow the verification link, and see the confirmed notice.
  test "S20: email verification link marks the account verified" do
    visit sign_up_path
    fill_in "Email",            with: "verifytest@example.com"
    fill_in "Password",         with: "password1234"
    fill_in "Confirm password", with: "password1234"
    click_on "Create account"

    assert_current_path monitors_path

    # The user exists but is not yet verified (email is sent asynchronously).
    user = User.find_by!(email_address: "verifytest@example.com")
    assert_nil user.verified_at

    # Simulate clicking the link in the verification email.
    token = user.generate_token_for(:email_verification)
    visit email_verification_path(token: token)

    assert_text "Email confirmed"
    assert user.reload.verified?
  end

  # S20b — an invalid/expired token bounces without verifying.
  test "S20b: an invalid verification token bounces without marking verified" do
    user = users(:bob)
    assert_nil user.verified_at

    visit email_verification_path(token: "not-a-real-token")

    # Bounced to root with an alert — account stays unverified.
    assert_text "invalid or has expired"
    assert_nil user.reload.verified_at
  end
end
