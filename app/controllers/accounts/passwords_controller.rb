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
    def update
      unless current_user.authenticate(params[:current_password].to_s)
        return render_account("That password is incorrect.")
      end

      # A blank password is a silent no-op in has_secure_password — it neither
      # clears nor sets the digest — so `update` would return true and we would
      # claim success while the old password still works (WU-11, same guard the
      # reset flow carries).
      return render_account("New password can't be blank.") if params[:password].blank?

      if current_user.update(params.permit(:password, :password_confirmation))
        current_user.sessions.where.not(id: Current.session.id).destroy_all
        redirect_to account_path, notice: "Password changed. Any other sessions have been signed out."
      else
        render_account(current_user.errors.full_messages.to_sentence)
      end
    end

    private
      # Re-render the account page in place. The user object may be dirty from a
      # rejected update, so reload it before the page reads it back.
      def render_account(alert)
        current_user.reload
        flash.now[:alert] = alert
        render template: "accounts/show", status: :unprocessable_entity
      end
  end
end
