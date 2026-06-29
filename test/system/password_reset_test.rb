require "application_system_test_case"

# Password reset flow (S19) — browser-driven. The email itself is not deliverable
# in tests, so we extract the token from the user object (the same way the link
# would be constructed), then drive the edit form directly. This covers the full
# user-visible path: forgot-password form → confirmation notice → reset form →
# sign in with new credentials.
class PasswordResetTest < ApplicationSystemTestCase
  # S19 — request a reset, follow the token link, set a new password, sign in.
  # The reset form fields have no labels (only placeholders), so we match by id.
  test "S19: password reset — request, set new password, sign in with new credentials" do
    user = users(:alice)

    # Step 1: request a reset via the forgot-password form.
    visit new_password_path
    assert_text "Forgot your password?"

    # No label on this field — the form uses a placeholder only; match by id.
    fill_in "email_address", with: user.email_address
    click_on "Email reset instructions"

    # Non-enumerating: always redirects to sign-in regardless of whether the
    # email is recognised, so we just verify the redirect happened.
    assert_current_path new_session_path

    # Step 2: visit the token URL (simulates clicking the link in the email).
    token = user.password_reset_token
    visit edit_password_path(token)
    assert_text "Update your password"

    # Reset form also uses placeholders, not labels — match by id.
    fill_in "password",              with: "hunter2newpass"
    fill_in "password_confirmation", with: "hunter2newpass"
    click_on "Save"

    # Redirected to sign-in after a successful reset.
    assert_current_path new_session_path

    # Step 3: sign in with the new credentials — must succeed.
    fill_in "Email",    with: user.email_address
    fill_in "Password", with: "hunter2newpass"
    click_on "Sign in"

    assert_current_path monitors_path
  end
end
