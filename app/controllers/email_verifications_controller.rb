class EmailVerificationsController < ApplicationController
  allow_unauthenticated_access only: :show

  # Nothing is gated on verification, so this is purely confirmatory.
  def show
    if (user = User.find_by_token_for(:email_verification, params[:token]))
      user.update!(verified_at: Time.current)
      redirect_to root_path, notice: "Email confirmed. Thanks!"
    else
      redirect_to root_path, alert: "That verification link is invalid or has expired."
    end
  end
end
