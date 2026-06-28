require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers
  def default_url_options = { host: "example.com", protocol: "https" }

  test "verification renders a confirmation link to the user's email" do
    user = users(:bob)
    mail = UserMailer.verification(user)

    assert_equal [ user.email_address ], mail.to
    assert_match "Confirm", mail.subject
    # A signed verification link is present (the token itself rotates per call,
    # so assert the verify route, then prove the embedded token actually resolves
    # back to this user).
    assert_match %r{https://example.com/verify/}, mail.body.encoded
    token = mail.body.encoded[%r{/verify/([^"<\s]+)}, 1]
    assert_equal user, User.find_by_token_for(:email_verification, token)
  end
end
