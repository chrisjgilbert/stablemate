module Accounts
  # The SIGNED-IN password change — a sub-resource of the account rather than a
  # custom verb (CLAUDE.md rule 4), and deliberately a different controller from
  # the top-level PasswordsController, which is the *unauthenticated* "I forgot
  # it" token-reset flow. The two share nothing: this one proves ownership with
  # the current password, that one with a signed emailed token.
  #
  # Session policy on success: this session survives, every OTHER session is
  # signed out. Changing your password is how you evict someone who has your
  # cookie, so the other sessions have to die — but re-prompting the person who
  # just typed both passwords proves nothing.
  class PasswordsController < ApplicationController
    # This form re-checks the same credential as the delete confirmation on the
    # account page, so the two must not add up to twice the guesses: one budget,
    # declared for both in AccountCredentials.
    include AccountCredentials

    rate_limit_account_credentials only: :update

    def update
      unless current_user.authenticate(params[:current_password].to_s)
        return render_account(WRONG_PASSWORD_MESSAGE)
      end

      # Guard the PERMITTED password, not the raw param — WU-11. Both halves of
      # that bug (a blank password, and a non-scalar one) are spelled out on
      # PasswordsController#update, which carries the same guard.
      attributes = params.permit(:password, :password_confirmation)
      return render_account("New password can't be blank.") if attributes[:password].blank?

      if current_user.update(attributes)
        current_user.sessions.where.not(id: Current.session.id).destroy_all
        redirect_to account_path, notice: "Password changed. Any other sessions have been signed out."
      else
        render_account(current_user.errors.full_messages.to_sentence)
      end
    end
  end
end
