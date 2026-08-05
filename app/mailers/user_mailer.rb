class UserMailer < ApplicationMailer
  def verification(user)
    @user = user
    @token = user.generate_token_for(:email_verification)

    mail to: user.email_address,
         subject: "Confirm your Stablemate email"
  end
end
