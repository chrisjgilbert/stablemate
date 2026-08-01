# Top-level coordinator (CLAUDE.md "process spanning entities, owned by none").
# Sign-up spans User + WaitlistSignup, so the orchestration lives here, not in the
# controller. The controller stays thin and asks Signup, then branches on the
# returned record's type.
#
# Below SIGNUP_ACCOUNT_CAP: create the user, send a non-blocking verification
# email, queue a Slack alert for the team (NotifySignupJob -> User::SignupAlert,
# also non-blocking), and return the User. At/over the cap (locked decision #7 — re-opened manually
# by raising the constant): create a WaitlistSignup instead — no User, no session,
# no email — queue the same kind of Slack alert (NotifyWaitlistSignupJob ->
# WaitlistSignup::SlackAlert) — and return it. A duplicate waitlist email is a
# friendly no-op success (find-then-create), never an error, never an
# enumeration oracle, and never a second Slack alert.
#
# Session creation stays in the controller because it needs the request (cookies).
class Signup
  attr_reader :record

  # Key for the Postgres advisory lock that serialises the cap check-and-create
  # (see #run). Arbitrary but stable, and the only advisory lock the app takes —
  # Postgres keeps one global int8 space for them, so a second use must pick a
  # different number.
  CAPACITY_LOCK_KEY = 8_474_101

  # Whether new sign-ups are currently gated to the waitlist. The controller asks
  # this to decide which mode of the sign-up screen to render. With no signup cap
  # configured (issue #16) sign-ups are always open and there is no waitlist.
  def self.at_capacity?
    return false unless Stablemate.signup_cap_enabled?

    User.count >= Stablemate::SIGNUP_ACCOUNT_CAP
  end

  def initialize(email:, password:, password_confirmation: nil)
    @email = email
    @password = password
    @password_confirmation = password_confirmation
  end

  # Returns either:
  #   - a created (or invalid, unpersisted) User — normal sign-up below the cap;
  #   - a persisted WaitlistSignup — when at/over the cap.
  # The controller branches on the class.
  def run
    user = create_user_within_cap

    # nil = at capacity. The waitlist branch deliberately runs OUTSIDE the lock:
    # it is already idempotent through its own unique index (a duplicate is a
    # friendly no-op) and holding the global signup lock across it would serialise
    # every waitlist join for nothing.
    return join_waitlist unless user

    announce(user) if user.persisted?
    user
  end

  private
    # The User half of #run: returns the created (or invalid, unpersisted) user,
    # or nil when the account cap is full and the caller should waitlist instead.
    def create_user_within_cap
      # No cap configured (issue #16, the self-host default): sign-ups are always
      # open, so there is no window to guard and no lock to pay for.
      return create_user unless Stablemate.signup_cap_enabled?

      # Serialise the whole check-then-create window. Without it two requests racing
      # for the last slot both read User.count < cap and both insert, taking the
      # account count past the cap — the same TOCTOU MonitorsController#create closes
      # with current_user.with_lock (WU-3). There is no row to lock FOR UPDATE here
      # (the cap is a global COUNT, and the row being created doesn't exist yet), so
      # we take a transaction-scoped Postgres advisory lock instead: no extra table,
      # no gem, released automatically on COMMIT/ROLLBACK, and free when uncontended.
      # The capacity re-check therefore runs inside the lock, against committed state.
      with_capacity_lock { create_user unless self.class.at_capacity? }
    end

    # The non-blocking side effects of a successful sign-up: the verification
    # email and the team's Slack alert. Deliberately runs AFTER the capacity lock
    # has committed — the queue lives in its own database, so a job enqueued
    # inside the open transaction can be picked up before the user row is visible
    # (F10) — and keeps the global signup lock off the enqueue path.
    def announce(user)
      user.send_verification_email
      NotifySignupJob.perform_later(user.id)
    end

    def with_capacity_lock(&block)
      User.transaction do
        User.with_connection do |connection|
          connection.execute(User.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", CAPACITY_LOCK_KEY ]))
        end
        block.call
      end
    end

    def create_user
      user = User.new(
        email_address: @email,
        password: @password,
        password_confirmation: @password_confirmation
      )

      # Insert in its OWN savepoint (requires_new) so a lost double-submit race
      # rolls back only this INSERT: Postgres aborts the whole enclosing
      # transaction on an index violation, which would take the capacity lock's
      # COMMIT — and any statement after the rescue below — down with it. Mirrors
      # Project::MonitorSync#save_isolated. (#run announces the new user once the
      # lock has been released.)
      User.transaction(requires_new: true) { user.save }
      user
    rescue ActiveRecord::RecordNotUnique
      # A double-submit (or two racing requests) for the same address: both passed
      # the uniqueness validation because neither row was committed yet, and the
      # unique index on lower(email_address) caught the second INSERT. Surface the
      # SAME friendly error the ordinary duplicate produces — the sign-up form
      # re-renders with "has already been taken" instead of a 500.
      user.errors.add(:email_address, :taken)
      user
    end

    # Always returns a WaitlistSignup so the controller has one type to branch on:
    #   - persisted (new row, or the existing one for a duplicate) -> success;
    #   - unpersisted with errors (e.g. a blank email) -> the form re-renders.
    # A duplicate is a friendly no-op: we return the existing row, never an error
    # and never a signal that the address was already on the list. The unique
    # index is the backstop for the find/create race.
    def join_waitlist
      signup = WaitlistSignup.new(email_address: @email)
      if signup.save
        NotifyWaitlistSignupJob.perform_later(signup.id)
        return signup
      end

      # save failed: a duplicate is a success (return the existing row); anything
      # else (e.g. blank email) keeps its validation errors for the form.
      existing = WaitlistSignup.find_by(email_address: signup.email_address)
      existing || signup
    rescue ActiveRecord::RecordNotUnique
      # Lost the find/create race — the row exists now; return it as a success.
      WaitlistSignup.find_by(email_address: signup.email_address) || signup
    end
end
