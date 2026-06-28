require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Scenario 1 — sign up creates a free, unverified user, starts a session, mails.
  test "sign up creates a user, starts a session, and sends a verification email" do
    assert_difference -> { User.count }, 1 do
      assert_enqueued_email_with UserMailer, :verification, args: ->(a) { a.first.email_address == "fresh@example.com" } do
        post sign_up_path, params: {
          email_address: "fresh@example.com",
          password: "password1234",
          password_confirmation: "password1234"
        }
      end
    end

    user = User.find_by(email_address: "fresh@example.com")
    assert_equal "free", user.plan
    assert_nil user.verified_at
    assert cookies[:session_id].present?
    assert_redirected_to root_path
  end

  # Scenario 2 — an unverified user can immediately create monitors (no gate).
  test "an unverified user can create a monitor right after signing up" do
    post sign_up_path, params: {
      email_address: "fresh@example.com", password: "password1234", password_confirmation: "password1234"
    }
    assert User.find_by(email_address: "fresh@example.com").verified_at.nil?

    assert_difference -> { Monitoring::Monitor.count }, 1 do
      post monitors_path, params: { monitor: { name: "First", expected_interval_seconds: 3600, grace_period_seconds: 300 } }
    end
  end

  test "invalid signup re-renders the form" do
    assert_no_difference -> { User.count } do
      post sign_up_path, params: { email_address: "", password: "x", password_confirmation: "y" }
    end
    assert_response :unprocessable_entity
  end
end
