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

  # The Slack alert job is queued for every successful signup; whether it
  # actually posts anywhere is gated inside User::SignupAlert (off by default
  # in test, like self-host — see test/models/user/signup_alert_test.rb), not
  # at enqueue time here.
  test "run queues a Slack alert job for a successfully created user" do
    user = nil
    assert_enqueued_with(job: NotifySignupJob, args: ->(args) { args == [ user.id ] }) do
      user = Signup.new(email: "with-slack@example.com", password: "password1234", password_confirmation: "password1234").run
    end
  end

  # Never fires for a failed/waitlisted signup — only a successfully created User.
  test "run does not queue a Slack alert job when signup fails" do
    assert_no_enqueued_jobs only: NotifySignupJob do
      Signup.new(email: users(:alice).email_address, password: "password1234", password_confirmation: "password1234").run
    end
  end

  test "run returns an invalid, unpersisted user when the email is taken" do
    assert_no_enqueued_emails do
      user = Signup.new(email: users(:alice).email_address, password: "password1234", password_confirmation: "password1234").run
      refute user.persisted?
      assert user.errors[:email_address].any?
    end
  end

  # Scenario 1/2 (model) — at the cap, run lands on the waitlist: a WaitlistSignup
  # is created, NO User, no verification email.
  test "at the cap, run creates a WaitlistSignup and no User" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      result = nil
      assert_no_enqueued_emails do
        assert_difference -> { WaitlistSignup.count }, 1 do
          assert_no_difference -> { User.count } do
            result = Signup.new(email: "waitlisted@example.com", password: "password1234").run
          end
        end
      end

      assert_kind_of WaitlistSignup, result
      assert result.persisted?
      assert_equal "waitlisted@example.com", result.email_address
    end
  end

  # Scenario 3 (model) — a duplicate waitlist email is a friendly success, not an
  # error, and creates no second row.
  test "at the cap, a duplicate waitlist email is a friendly no-op success" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      WaitlistSignup.create!(email_address: "again@example.com")

      result = nil
      assert_no_difference -> { WaitlistSignup.count } do
        result = Signup.new(email: "AGAIN@example.com", password: "password1234").run
      end

      assert_kind_of WaitlistSignup, result
      assert result.persisted?
      assert result.errors.empty?, "duplicate waitlist signup must not surface errors"
    end
  end

  # Scenario 4/5 (model) — below the cap (or after raising it), normal sign-up.
  test "below the cap, run creates a User as normal" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      result = nil
      assert_difference -> { User.count }, 1 do
        result = Signup.new(email: "under-cap@example.com", password: "password1234", password_confirmation: "password1234").run
      end
      assert_kind_of User, result
      assert result.persisted?
    end
  end

  # Caps OFF (issue #16, self-host default): sign-ups always open, never waitlisted,
  # even when the account count exceeds what would have been the managed cap.
  test "with the signup cap OFF, at_capacity? is false and run always creates a User" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, 0) do
      refute Signup.at_capacity?

      result = nil
      assert_no_difference -> { WaitlistSignup.count } do
        assert_difference -> { User.count }, 1 do
          result = Signup.new(email: "always-open@example.com", password: "password1234").run
        end
      end
      assert_kind_of User, result
      assert result.persisted?
    end
  end
end
