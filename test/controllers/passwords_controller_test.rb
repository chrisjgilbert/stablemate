require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_password_path
    assert_response :success
  end

  test "create" do
    post passwords_path, params: { email_address: @user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @user ]
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "reset instructions sent"
  end

  test "create for an unknown user redirects but sends no mail" do
    post passwords_path, params: { email_address: "missing-user@example.com" }
    assert_enqueued_emails 0
    assert_redirected_to new_session_path

    follow_redirect!
    assert_notice "reset instructions sent"
  end

  test "edit" do
    get edit_password_path(@user.password_reset_token)
    assert_response :success
  end

  test "edit with invalid password reset token" do
    get edit_password_path("invalid token")
    assert_redirected_to new_password_path

    follow_redirect!
    assert_notice "reset link is invalid"
  end

  test "update" do
    assert_changes -> { @user.reload.password_digest } do
      put password_path(@user.password_reset_token), params: { password: "newpassword1", password_confirmation: "newpassword1" }
      assert_redirected_to new_session_path
    end

    follow_redirect!
    assert_notice "Password has been reset"
  end

  test "update with non matching passwords" do
    token = @user.password_reset_token
    assert_no_changes -> { @user.reload.password_digest } do
      put password_path(token), params: { password: "no", password_confirmation: "match" }
      assert_redirected_to edit_password_path(token)
    end

    follow_redirect!
    assert_notice "Passwords did not match"
  end

  # WU-11 — a blank password must NOT report success: it's a no-op in
  # has_secure_password, so without this guard the user is logged out everywhere
  # and told "reset" while the old password still works.
  test "update with a blank password is rejected and changes nothing" do
    user = users(:alice)
    session = user.sessions.create!
    token = user.password_reset_token

    assert_no_changes -> { user.reload.password_digest } do
      put password_path(token), params: { password: "", password_confirmation: "" }
    end
    assert_redirected_to edit_password_path(token)
    assert user.sessions.exists?(session.id), "sessions must not be revoked on a rejected reset"
    assert User.authenticate_by(email_address: user.email_address, password: "password1234"),
      "the old password must still work"
  end

  # Full happy path: request reset -> email enqueued -> follow the token to edit
  # -> update -> existing sessions revoked, the new password authenticates and the
  # old one no longer does. (Fixtures share the password "password1234".)
  test "the reset flow ends in a usable new password and revoked sessions" do
    user = users(:alice)
    user.sessions.create! # a live session the reset must revoke

    post passwords_path, params: { email_address: user.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ user ]

    token = user.password_reset_token
    get edit_password_path(token)
    assert_response :success

    assert_changes -> { user.sessions.count }, to: 0 do
      put password_path(token), params: { password: "brandnewpass9", password_confirmation: "brandnewpass9" }
    end
    assert_redirected_to new_session_path

    assert User.authenticate_by(email_address: user.email_address, password: "brandnewpass9")
    assert_nil User.authenticate_by(email_address: user.email_address, password: "password1234")
  end

  private
    def assert_notice(text)
      assert_select "div", /#{text}/
    end
end
