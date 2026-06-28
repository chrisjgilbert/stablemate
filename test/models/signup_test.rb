require "test_helper"

class SignupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  # Scenario 1 (model part) — creates a free, unverified user + verification email.
  test "run creates a free, unverified user and enqueues a verification email" do
    user = nil
    assert_enqueued_email_with UserMailer, :verification, args: ->(args) { args.first == user } do
      user = Signup.new(email: "new@example.com", password: "password1234", password_confirmation: "password1234").run
    end

    assert user.persisted?
    assert_equal "free", user.plan
    assert_nil user.verified_at
  end

  test "run returns an invalid, unpersisted user when the email is taken" do
    assert_no_enqueued_emails do
      user = Signup.new(email: users(:alice).email_address, password: "password1234", password_confirmation: "password1234").run
      refute user.persisted?
      assert user.errors[:email_address].any?
    end
  end
end
