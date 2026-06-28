require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  test "a valid token marks the user verified" do
    user = users(:bob)
    assert_nil user.verified_at

    get email_verification_path(token: user.generate_token_for(:email_verification))

    assert user.reload.verified?
    assert_redirected_to root_path
  end

  test "an invalid token bounces without verifying" do
    get email_verification_path(token: "garbage")
    assert_redirected_to root_path
    assert_nil users(:bob).reload.verified_at
  end
end
