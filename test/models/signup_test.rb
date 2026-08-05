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

  # There is also an unlocked capacity COUNT before the lock, which is why this
  # asks for a count AFTER it rather than for the first one: that pre-check is
  # deliberately not the decision (it only spares a waitlist join the cost of a
  # password hash), and being stale either way is harmless. The decision — the
  # count the INSERT is predicated on — has to be re-made under the lock.
  test "the create path takes the capacity lock before it counts accounts and inserts the user" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      statements = sql_executed_during do
        Signup.new(email: "locked@example.com", password: "password1234").run
      end

      lock   = index_of(statements, /pg_advisory_xact_lock/)
      counts = indexes_of(statements, /COUNT\(\*\).+"users"/i)
      insert = index_of(statements, /INSERT INTO "users"/)

      assert lock, "expected the signup to take an advisory lock"
      assert counts.any?, "expected the signup to count accounts against the cap"
      assert insert, "expected the signup to insert the user"
      assert counts.any? { |i| i > lock && i < insert },
        "the cap decision must be re-made under the lock, BEFORE the INSERT it gates"
      assert lock < insert, "the INSERT must run under the lock, not before it"
    end
  end

  # The corollary of hashing before the lock: don't hash at all for someone who
  # is going to the waitlist. Once the managed instance is full that is every
  # sign-up, so paying ~250ms of bcrypt for a password we never store would just
  # move the waste rather than remove it.
  test "a waitlisted sign-up never pays for a password hash" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count) do
      events = capture_hashing_and_locking do
        Signup.new(email: "no-hash@example.com", password: "password1234").run
      end

      assert_empty events
    end
  end

  # …but ONLY the COUNT and the INSERT belong in there. bcrypt is deliberately
  # slow (~250ms at the configured cost) and has nothing to do with capacity, so
  # hashing the password under the global lock made every sign-up on a capped
  # instance queue behind every other one's password hashing. Build the user —
  # has_secure_password digests in the setter — before the lock is taken.
  test "the password is hashed before the capacity lock is taken" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      events = capture_hashing_and_locking do
        Signup.new(email: "hashed-first@example.com", password: "password1234").run
      end

      assert_equal %i[hash lock], events.first(2),
        "bcrypt must not run while every other sign-up is blocked behind the lock"
    end
  end

  # Every consult is recorded, not just the last. There are two now — the unlocked
  # pre-check that spares a waitlist join the cost of a password hash, then the one
  # the INSERT is predicated on — and only the second is a decision. Reading the
  # final result alone would go on passing if the two ever swapped places, which is
  # exactly the regression that would reopen M1.
  test "the capacity lock excludes a second connection while capacity is being decided" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      taken_elsewhere = []

      while_deciding_capacity(-> { taken_elsewhere << try_capacity_lock_on_another_connection }) do
        Signup.new(email: "excluded@example.com", password: "password1234").run
      end

      assert_equal [ true, false ], taken_elsewhere,
        "the deciding consult must exclude a second connection; the cheap pre-check need not"
    end
  end

  test "with the signup cap OFF there is no window to guard, so no lock is taken" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, 0) do
      statements = sql_executed_during do
        Signup.new(email: "unlocked@example.com", password: "password1234").run
      end

      assert_nil index_of(statements, /pg_advisory_xact_lock/),
        "an uncapped instance must not pay for the signup lock"
    end
  end

  # The capacity lock must not swallow the sign-up's side effects: the queue
  # lives in its own database, so a job enqueued while the app transaction is
  # still open can be picked up before the user row is visible (F10). It also
  # keeps the global signup lock off the enqueue path.
  test "the verification email and alert job are enqueued outside the capacity lock" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      baseline = User.with_connection(&:open_transactions)
      depths = []
      subscriber = ActiveSupport::Notifications.subscribe("enqueue.active_job") do
        depths << User.with_connection(&:open_transactions)
      end

      Signup.new(email: "after-commit@example.com", password: "password1234").run

      assert depths.any?, "expected the sign-up to enqueue the email and the alert"
      assert_equal [ baseline ] * depths.size, depths,
        "nothing may be enqueued while the capacity-lock transaction is open"
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  # --- M2: a double-submit must not 500 -------------------------------------
  #
  # Two identical sign-ups arriving together both pass the uniqueness validation
  # (neither row is committed yet) and the second INSERT hits the unique index on
  # lower(email_address). Staged by committing the competing row from a
  # before_create callback — after validation, before our INSERT — which is
  # exactly where the real race lands.

  test "a duplicate that slips past the validation surfaces the friendly error, not RecordNotUnique" do
    result = nil
    racing_user_insert_of("racer@example.com") do
      result = Signup.new(email: "racer@example.com", password: "password1234", password_confirmation: "password1234").run
    end

    assert_kind_of User, result
    refute result.persisted?
    assert_includes result.errors[:email_address], "has already been taken"
  end

  test "a duplicate that slips past the validation leaves the capacity-lock transaction usable" do
    stub_const(Stablemate, :SIGNUP_ACCOUNT_CAP, User.count + 1) do
      result = nil
      racing_user_insert_of("locked-racer@example.com") do
        result = Signup.new(email: "locked-racer@example.com", password: "password1234").run
      end

      assert_includes result.errors[:email_address], "has already been taken"
      # The index violation must be confined to its own savepoint: without one,
      # Postgres aborts the enclosing capacity-lock transaction and every
      # statement after the rescue fails.
      assert_nothing_raised { User.count }
    end
  end

  test "the racing insert really does violate the unique index" do
    # Guard for the two tests above: if the staged duplicate ever stopped
    # colliding they would pass for the wrong reason.
    assert_raises ActiveRecord::RecordNotUnique do
      racing_user_insert_of("guard@example.com") do
        User.create!(email_address: "guard@example.com", password: "password1234")
      end
    end
  end

  private
    # Commit a competing user with the same address from inside User's
    # before_create — i.e. after the uniqueness validation has already passed —
    # so the next INSERT hits the unique index, exactly as a double-submit does.
    def racing_user_insert_of(email)
      raced = false
      racer = ->(*_args) do
        next if raced

        raced = true
        User.insert!({ email_address: email, password_digest: "raced",
                       created_at: Time.current, updated_at: Time.current })
      end

      User.set_callback(:create, :before, racer)
      yield
    ensure
      User.skip_callback(:create, :before, racer, raise: false)
    end

    def index_of(statements, pattern)
      statements.index { |sql| sql.match?(pattern) }
    end

    def indexes_of(statements, pattern)
      statements.each_index.select { |i| statements[i].match?(pattern) }
    end

    # The ORDER of the two things that must not overlap: the password hash and the
    # global capacity lock. bcrypt leaves no SQL behind, so it is watched at its
    # own entry point rather than through the query log.
    def capture_hashing_and_locking
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        events << :lock if payload[:sql].to_s.match?(/pg_advisory_xact_lock/)
      end
      original = BCrypt::Password.method(:create)
      BCrypt::Password.define_singleton_method(:create) do |*args, **kwargs|
        events << :hash
        original.call(*args, **kwargs)
      end

      yield
      events
    ensure
      BCrypt::Password.define_singleton_method(:create, original) if original
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
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
