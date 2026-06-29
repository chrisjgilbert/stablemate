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

  # The post-signup welcome notice survives the root -> /monitors bounce
  # (PagesController#home does flash.keep).
  test "the welcome notice reaches the dashboard after the root redirect" do
    post sign_up_path, params: {
      email_address: "welcomed@example.com", password: "password1234", password_confirmation: "password1234"
    }
    assert_redirected_to root_path

    follow_redirect! # / -> redirects signed-in user to /monitors, keeping the flash
    assert_redirected_to monitors_path
    follow_redirect!
    assert_match "Welcome to Stablemate.", response.body
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

  # Scenario 1 — at the cap, GET /sign_up renders waitlist mode: email field, no
  # password field.
  test "at capacity, the sign-up screen renders waitlist mode (no password field)" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      get sign_up_path
      assert_response :success
      assert_select "input[type=email]"
      assert_select "input[type=password]", count: 0
      assert_select "[data-testid=waitlist-form]"
    end
  end

  # Scenario 2 — submitting in waitlist mode creates a WaitlistSignup, no User, no
  # session, and shows the calm success.
  test "at capacity, submitting creates a WaitlistSignup with no User and no session" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      assert_difference -> { WaitlistSignup.count }, 1 do
        assert_no_difference -> { User.count } do
          post sign_up_path, params: { email_address: "joiner@example.com" }
        end
      end

      assert_nil cookies[:session_id].presence
      follow_redirect!
      assert_match(/on the list/i, response.body)
    end
  end

  # Scenario 3 — a duplicate waitlist email is a friendly success, not an error.
  test "at capacity, a duplicate waitlist email is a friendly success" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      WaitlistSignup.create!(email_address: "twice@example.com")

      assert_no_difference -> { WaitlistSignup.count } do
        post sign_up_path, params: { email_address: "TWICE@example.com" }
      end

      assert_response :redirect
      follow_redirect!
      assert_match(/on the list/i, response.body)
    end
  end

  # At capacity, a blank email re-renders the waitlist form (no crash, no row).
  test "at capacity, a blank waitlist email re-renders the form without creating a row" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      assert_no_difference -> { WaitlistSignup.count } do
        post sign_up_path, params: { email_address: "" }
      end
      assert_response :unprocessable_entity
      assert_select "[data-testid=waitlist-form]"
    end
  end

  # Caps OFF (issue #16, self-host default): the waitlist mode is unreachable even
  # when the account count exceeds what would have been the managed cap; GET
  # renders the normal form and POST creates a User + session.
  test "with the signup cap OFF, the waitlist is never rendered and signup creates a user" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, 0) do
      get sign_up_path
      assert_response :success
      assert_select "input[type=password]"
      assert_select "[data-testid=waitlist-form]", count: 0

      assert_difference -> { User.count }, 1 do
        assert_no_difference -> { WaitlistSignup.count } do
          post sign_up_path, params: {
            email_address: "self-host@example.com", password: "password1234", password_confirmation: "password1234"
          }
        end
      end
      assert cookies[:session_id].present?
    end
  end

  # Scenario 5 — raising the cap re-opens normal sign-up.
  test "raising the cap re-opens normal sign-up" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      assert_difference -> { User.count }, 1 do
        post sign_up_path, params: {
          email_address: "reopened@example.com", password: "password1234", password_confirmation: "password1234"
        }
      end
      assert cookies[:session_id].present?
    end
  end
end
