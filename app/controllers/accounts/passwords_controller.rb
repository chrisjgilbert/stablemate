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
    # Shares AccountsController's per-user attempt budget — same credential, same
    # oracle, so the two forms must not add up to twice the guesses. See the
    # comment on that constant for why a signed-in surface needs a bound at all.
    rate_limit to: ::AccountsController::CREDENTIAL_ATTEMPT_LIMIT,
      within: ::AccountsController::CREDENTIAL_ATTEMPT_WINDOW,
      by: -> { Current.user.id },
      scope: ::AccountsController::CREDENTIAL_ATTEMPT_SCOPE,
      store: ::AccountsController::RATE_LIMIT_STORE,
      with: -> { render_account(::AccountsController::THROTTLED_MESSAGE, status: :too_many_requests) }

    def update
      unless current_user.authenticate(params[:current_password].to_s)
        return render_account("That password is incorrect.")
      end

      # Guard the PERMITTED password, not the raw param. A blank one is a silent
      # no-op in has_secure_password — it neither clears nor sets the digest — so
      # `update` would return true and we would claim success while the old
      # password still works (WU-11, same guard the reset flow carries). A
      # non-scalar one (`password[]=…`) is the same bug one step along: it passes
      # `.blank?` on the raw param but strong parameters drop it, so `update` gets
      # an empty hash and returns true just the same. Reading the guard off the
      # attributes we are actually about to write closes both.
      attributes = params.permit(:password, :password_confirmation)
      return render_account("New password can't be blank.") if attributes[:password].blank?

      if current_user.update(attributes)
        current_user.sessions.where.not(id: Current.session.id).destroy_all
        redirect_to account_path, notice: "Password changed. Any other sessions have been signed out."
      else
        render_account(current_user.errors.full_messages.to_sentence)
      end
    end

    private
      # Re-render the account page in place. The user object may be dirty from a
      # rejected update, so reload it before the page reads it back.
      def render_account(alert, status: :unprocessable_entity)
        current_user.reload
        flash.now[:alert] = alert
        render template: "accounts/show", status: status
      end
  end
end
