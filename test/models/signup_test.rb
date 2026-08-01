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

  # The Slack alert job is queued for every successful waitlist join, mirroring
  # the User signup alert; whether it actually posts anywhere is gated inside
  # WaitlistSignup::SlackAlert (see test/models/waitlist_signup/slack_alert_test.rb).
  test "at the cap, run queues a Slack alert job for a new waitlist signup" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      result = nil
      assert_enqueued_with(job: NotifyWaitlistSignupJob, args: ->(args) { args == [ result.id ] }) do
        result = Signup.new(email: "waitlist-slack@example.com", password: "password1234").run
      end
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

  # Never fires a second alert for a duplicate — only a genuinely new row.
  test "at the cap, run does not queue a Slack alert job for a duplicate waitlist email" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      WaitlistSignup.create!(email_address: "already-alerted@example.com")

      assert_no_enqueued_jobs only: NotifyWaitlistSignupJob do
        Signup.new(email: "ALREADY-ALERTED@example.com", password: "password1234").run
      end
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

  # --- M1: the cap check-and-create must not race ---------------------------
  #
  # A true two-request race can't be staged here: the suite runs inside
  # transactional fixtures on a single pinned connection, so two committing
  # signups aren't expressible. These three tests pin the property that makes the
  # race impossible instead — (a) the capacity COUNT and the INSERT both happen
  # *after* the lock is taken, so the window between them can't be entered twice;
  # (b) the lock genuinely excludes a second database connection while that
  # decision is being made (probed from a real second connection); and (c) with
  # the cap off there is no window to guard, so no lock is taken at all.

  test "the create path takes the capacity lock before it counts accounts and inserts the user" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      statements = capture_sql do
        Signup.new(email: "locked@example.com", password: "password1234").run
      end

      lock   = index_of(statements, /pg_advisory_xact_lock/)
      count  = index_of(statements, /COUNT\(\*\).+"users"/i)
      insert = index_of(statements, /INSERT INTO "users"/)

      assert lock, "expected the signup to take an advisory lock"
      assert count, "expected the signup to count accounts against the cap"
      assert insert, "expected the signup to insert the user"
      assert lock < count, "the cap COUNT must run under the lock, not before it"
      assert lock < insert, "the INSERT must run under the lock, not before it"
    end
  end

  test "the capacity lock excludes a second connection while capacity is being decided" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      taken_elsewhere = nil

      while_deciding_capacity(-> { taken_elsewhere = try_capacity_lock_on_another_connection }) do
        Signup.new(email: "excluded@example.com", password: "password1234").run
      end

      assert_equal false, taken_elsewhere,
        "a second connection must not be able to enter the check-then-create window"
    end
  end

  test "with the signup cap OFF there is no window to guard, so no lock is taken" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, 0) do
      statements = capture_sql do
        Signup.new(email: "unlocked@example.com", password: "password1234").run
      end

      assert_nil index_of(statements, /pg_advisory_xact_lock/),
        "an uncapped instance must not pay for the signup lock"
    end
  end

  private
    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql]
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def index_of(statements, pattern)
      statements.index { |sql| sql.match?(pattern) }
    end

    # Run `probe` at the moment Signup consults the cap — i.e. inside the window
    # the lock is supposed to close.
    def while_deciding_capacity(probe)
      original = Signup.method(:at_capacity?)
      Signup.define_singleton_method(:at_capacity?) do
        probe.call
        original.call
      end
      yield
    ensure
      Signup.define_singleton_method(:at_capacity?, original)
    end

    # Try to take the signup lock from a genuinely separate database connection
    # (the pooled one is pinned to this transactional test, so it would re-enter
    # its own lock). Non-blocking try-lock, rolled back immediately: it writes
    # nothing and can never deadlock the suite.
    def try_capacity_lock_on_another_connection
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      conn = PG.connect(dbname: config[:database], host: config[:host],
                        port: config[:port], user: config[:username], password: config[:password])
      conn.exec("BEGIN")
      conn.exec("SELECT pg_try_advisory_xact_lock(#{Signup::CAPACITY_LOCK_KEY})").getvalue(0, 0) == "t"
    ensure
      conn&.exec("ROLLBACK")
      conn&.close
    end
end
