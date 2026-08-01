require "application_system_test_case"

# The account page (launch-readiness §5 / WS-D), browser-driven. Both flows here
# are destructive to the user's own credentials, so they are exactly the kind
# that has to be proven through the rendered UI rather than inferred from a
# request test: the whole point is that a real person can find the page, confirm,
# and end up somewhere sensible.
class AccountTest < ApplicationSystemTestCase
  setup do
    @user = users(:alice)
  end

  test "delete the account from the nav, land on the marketing page, and stay locked out" do
    sign_in @user
    click_on "Account"

    assert_current_path account_path
    assert_text @user.email_address
    assert_text "Verified"
    assert_text "Delete this account"

    # A wrong password is refused, and the account is still there.
    within "[data-testid='danger-zone']" do
      fill_in "Type your password to confirm", with: "not-my-password"
      click_on "Delete my account"
    end
    assert_text "That password is incorrect."
    assert_current_path account_path

    within "[data-testid='danger-zone']" do
      fill_in "Type your password to confirm", with: "password1234"
      click_on "Delete my account"
    end

    # Signed out, back on the public marketing page.
    assert_text "Your account has been deleted."
    assert_current_path root_path
    assert_text "Super simple job monitoring for Rails"

    # The credentials are dead: signing in again fails.
    visit sign_in_path
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "password1234"
    click_on "Sign in"

    assert_text "Try another email address or password"
    assert_current_path new_session_path
  end

  test "change the password and sign back in with the new one" do
    sign_in @user
    click_on "Account"

    within "[data-testid='change-password']" do
      fill_in "Current password", with: "wrong-password"
      fill_in "New password", with: "newpassword12"
      fill_in "Confirm new password", with: "newpassword12"
      click_on "Change password"
    end
    assert_text "That password is incorrect."

    within "[data-testid='change-password']" do
      fill_in "Current password", with: "password1234"
      fill_in "New password", with: "newpassword12"
      fill_in "Confirm new password", with: "newpassword12"
      click_on "Change password"
    end
    assert_text "Password changed."

    # Still signed in on this device — the change doesn't kick you out.
    assert_current_path account_path
    click_on "Monitors"
    assert_current_path monitors_path

    click_on "Sign out"
    fill_in "Email", with: @user.email_address
    fill_in "Password", with: "newpassword12"
    click_on "Sign in"
    assert_current_path monitors_path
  end
end
