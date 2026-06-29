# Top-level coordinator (CLAUDE.md "process spanning entities, owned by none").
# Sign-up spans User + WaitlistSignup, so the orchestration lives here, not in the
# controller. The controller stays thin and asks Signup, then branches on the
# returned record's type.
#
# Below SIGNUP_ACCOUNT_CAP: create the user, send a non-blocking verification
# email, return the User. At/over the cap (locked decision #7 — re-opened manually
# by raising the constant): create a WaitlistSignup instead — no User, no session,
# no email — and return it. A duplicate waitlist email is a friendly no-op success
# (find-then-create), never an error and never an enumeration oracle.
#
# Session creation stays in the controller because it needs the request (cookies).
class Signup
  attr_reader :record

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
    self.class.at_capacity? ? join_waitlist : create_user
  end

  private
    def create_user
      user = User.new(
        email_address: @email,
        password: @password,
        password_confirmation: @password_confirmation
      )

      user.send_verification_email if user.save
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
      return signup if signup.save

      # save failed: a duplicate is a success (return the existing row); anything
      # else (e.g. blank email) keeps its validation errors for the form.
      existing = WaitlistSignup.find_by(email_address: signup.email_address)
      existing || signup
    rescue ActiveRecord::RecordNotUnique
      # Lost the find/create race — the row exists now; return it as a success.
      WaitlistSignup.find_by(email_address: signup.email_address) || signup
    end
end
