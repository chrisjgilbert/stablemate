require "test_helper"

# The SIGNED-IN password change (launch-readiness §5 / WS-D) — a sub-resource of
# the account, deliberately distinct from PasswordsController's unauthenticated
# token-reset flow. The current password is required, so a stolen session cookie
# alone can't lock the real owner out.
class Accounts::PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
  end

  def change_password(current: "password1234", password: "newpassword12", confirmation: nil)
    patch account_password_path, params: {
      current_password: current,
      password: password,
      password_confirmation: confirmation.nil? ? password : confirmation
    }
  end

  test "anonymous users are redirected to sign in" do
    patch account_password_path, params: { current_password: "x", password: "y" }
    assert_redirected_to new_session_path
  end

  test "the wrong current password is a 422 and changes nothing" do
    sign_in @user
    change_password(current: "not-my-password")

    assert_response :unprocessable_entity
    assert_match "That password is incorrect.", response.body
    assert @user.reload.authenticate("password1234")
  end

  # A blank password is a silent no-op in has_secure_password: it neither clears
  # nor sets the digest, so `update` returns true and we would claim success
  # while the old password still works (the WU-11 bug, same guard as the reset
  # flow).
  test "a blank new password is a 422 and changes nothing" do
    sign_in @user
    change_password(password: "")

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password1234")
  end

  test "a mismatched confirmation is a 422 and changes nothing" do
    sign_in @user
    change_password(password: "newpassword12", confirmation: "somethingelse")

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password1234")
  end

  test "a too-short password is a 422 and changes nothing" do
    sign_in @user
    change_password(password: "short")

    assert_response :unprocessable_entity
    assert @user.reload.authenticate("password1234")
  end

  test "a valid change sets the new password and keeps this session signed in" do
    sign_in @user
    change_password(password: "newpassword12")

    assert_redirected_to account_path
    assert @user.reload.authenticate("newpassword12")
    assert_not @user.authenticate("password1234")

    # Still signed in here — no re-prompt after changing your own password.
    get account_path
    assert_response :success
  end

  # Everywhere else is signed out: changing a password is how you evict someone
  # who has your session, and that only works if the other sessions die.
  test "a valid change signs out every other session" do
    other = @user.sessions.create!(user_agent: "other device", ip_address: "10.0.0.1")
    sign_in @user
    mine = @user.sessions.order(:created_at).last

    change_password(password: "newpassword12")

    assert_not Session.exists?(other.id)
    assert Session.exists?(mine.id)
  end
end
