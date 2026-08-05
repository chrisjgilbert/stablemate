# Top-level coordinator (CLAUDE.md "process spanning entities, owned by none").
# Sign-up spans User + WaitlistSignup, so the orchestration lives here, not in the
# controller. The controller stays thin and branches on the returned record's type.
#
# Session creation stays in the controller because it needs the request (cookies).
class Signup
  attr_reader :record

  # Arbitrary but stable, and the only advisory lock the app takes — Postgres keeps
  # one global int8 space for them, so a second use must pick a different number.
  CAPACITY_LOCK_KEY = 8_474_101

  # With no signup cap configured sign-ups are always open and there is no waitlist.
  def self.at_capacity?
    return false unless Stablemate.signup_cap_enabled?

    User.count >= Stablemate::SIGNUP_ACCOUNT_CAP
  end

  def initialize(email:, password:, password_confirmation: nil)
    @email = email
    @password = password
    @password_confirmation = password_confirmation
  end

  # Returns either a created (or invalid, unpersisted) User below the cap, or a
  # persisted WaitlistSignup at/over it. The controller branches on the class.
  def run
    user = create_user_within_cap

    # nil = at capacity. The waitlist branch deliberately runs OUTSIDE the lock: it
    # is already idempotent through its own unique index, and holding the global
    # signup lock across it would serialise every waitlist join for nothing.
    return join_waitlist unless user

    announce(user) if user.persisted?
    user
  end

  private
    def create_user_within_cap
      return save_user(build_user) unless Stablemate.signup_cap_enabled?

      # An unlocked pre-check that is NOT the decision — the authoritative one is
      # made under the lock below. It exists so that someone headed for the
      # waitlist doesn't pay for a password hash we are never going to store.
      # Being stale is harmless in both directions.
      return nil if self.class.at_capacity?

      # Build the record — and with it the bcrypt hash, which has_secure_password
      # computes right there in the setter — BEFORE the lock is taken. bcrypt is
      # deliberately slow (~250ms) and has nothing to do with capacity, so hashing
      # under the global lock made every sign-up queue behind every other one's
      # password.
      user = build_user

      # Serialise the whole check-then-create window, or two requests racing for
      # the last slot both read User.count < cap and both insert. There is no row
      # to lock FOR UPDATE here (the cap is a global COUNT, and the row being
      # created doesn't exist yet), so we take a transaction-scoped Postgres
      # advisory lock instead: released automatically on COMMIT/ROLLBACK, and free
      # when uncontended.
      with_capacity_lock { save_user(user) unless self.class.at_capacity? }
    end

    # Deliberately runs AFTER the capacity lock has committed — the queue lives in
    # its own database, so a job enqueued inside the open transaction can be picked
    # up before the user row is visible.
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

    # Unsaved, and already carrying its password_digest — see create_user_within_cap
    # for why that matters.
    def build_user
      User.new(
        email_address: @email,
        password: @password,
        password_confirmation: @password_confirmation
      )
    end

    def save_user(user)
      # Insert in its OWN savepoint (requires_new) so a lost double-submit race
      # rolls back only this INSERT: Postgres aborts the whole enclosing
      # transaction on an index violation, which would take the capacity lock's
      # COMMIT — and any statement after the rescue below — down with it.
      User.transaction(requires_new: true) { user.save }
      user
    rescue ActiveRecord::RecordNotUnique
      # Both passed the uniqueness validation because neither row was committed
      # yet, and the unique index on lower(email_address) caught the second INSERT.
      # Surface the SAME friendly error the ordinary duplicate produces.
      user.errors.add(:email_address, :taken)
      user
    end

    # Always returns a WaitlistSignup so the controller has one type to branch on.
    # A duplicate is a friendly no-op: we return the existing row, never an error
    # and never a signal that the address was already on the list.
    def join_waitlist
      signup = WaitlistSignup.new(email_address: @email)
      if signup.save
        NotifyWaitlistSignupJob.perform_later(signup.id)
        return signup
      end

      existing = WaitlistSignup.find_by(email_address: signup.email_address)
      existing || signup
    rescue ActiveRecord::RecordNotUnique
      WaitlistSignup.find_by(email_address: signup.email_address) || signup
    end
end
