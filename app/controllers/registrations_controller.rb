class RegistrationsController < ApplicationController
  # Sign-up is open to anonymous visitors.
  allow_unauthenticated_access only: %i[new create]

  def new
    @user = User.new
  end

  def create
    signup = Signup.new(
      email: params[:email_address],
      password: params[:password],
      password_confirmation: params[:password_confirmation]
    )
    @user = signup.run

    if @user.persisted?
      start_new_session_for @user
      redirect_to root_path, notice: "Welcome to Stablemate."
    else
      # NOTE: a taken email surfaces "has already been taken", which is a mild
      # account-enumeration oracle. Accepted for open signup (the norm; the value
      # of a clear error outweighs it). The password-reset flow, where the stakes
      # are higher, deliberately stays non-enumerating.
      render :new, status: :unprocessable_entity
    end
  end
end
