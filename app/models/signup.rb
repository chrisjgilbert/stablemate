# Top-level coordinator (CLAUDE.md "process spanning entities, owned by none").
# Sign-up spans User + (in Phase 4) WaitlistSignup, so the orchestration lives
# here, not in the controller. The controller stays thin and asks Signup.
#
# Phase 1 form (STUB): create the user, send a non-blocking verification email,
# and return the user. The at-capacity -> waitlist branch (gated on
# SIGNUP_ACCOUNT_CAP) lands in Phase 4; session creation stays in the controller
# because it needs the request (cookies).
class Signup
  attr_reader :user

  def initialize(email:, password:, password_confirmation: nil)
    @email = email
    @password = password
    @password_confirmation = password_confirmation
  end

  # Returns the created User on success, or an unpersisted User carrying
  # validation errors on failure (the controller re-renders the form).
  def run
    @user = User.new(
      email_address: @email,
      password: @password,
      password_confirmation: @password_confirmation
    )

    if @user.save
      @user.send_verification_email
    end

    @user
  end
end
