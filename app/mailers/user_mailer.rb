class UserMailer < ApplicationMailer
  # Non-blocking account verification email sent on signup. The token is a
  # signed, expiring token (generates_token_for) — no DB column needed.
  def verification(user)
    @user = user
    @token = user.generate_token_for(:email_verification)

    mail to: user.email_address,
         subject: "Confirm your Stablemate email"
  end
end
