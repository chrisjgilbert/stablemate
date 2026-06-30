class RegistrationsController < ApplicationController
  # Sign-up is open to anonymous visitors.
  allow_unauthenticated_access only: %i[new create]

  def new
    @user = User.new
    @waitlist = Signup.at_capacity?
  end

  def create
    record = Signup.new(
      email: params[:email_address],
      password: params[:password],
      password_confirmation: params[:password_confirmation]
    ).run

    case record
    when WaitlistSignup
      join_waitlist(record)
    else
      complete_signup(record)
    end
  end

  private
    def join_waitlist(signup)
      if signup.persisted?
        redirect_to sign_up_path,
          notice: "You're on the list — we'll email you an invite. Need it sooner? Email support@stablemate.dev."
      else
        # A blank/invalid email at capacity: re-render the waitlist form. (Errors
        # are generic — "can't be blank" — so this never becomes an enumeration
        # oracle for who is already on the list; a duplicate is a success above.)
        @waitlist_signup = signup
        @waitlist = true
        render :new, status: :unprocessable_entity
      end
    end

    def complete_signup(user)
      if user.persisted?
        start_new_session_for user
        redirect_to root_path, notice: "Welcome to Stablemate."
      else
        # NOTE: a taken email surfaces "has already been taken", which is a mild
        # account-enumeration oracle. Accepted for open signup (the norm; the value
        # of a clear error outweighs it). The password-reset flow, where the stakes
        # are higher, deliberately stays non-enumerating.
        @user = user
        @waitlist = false
        render :new, status: :unprocessable_entity
      end
    end
end
