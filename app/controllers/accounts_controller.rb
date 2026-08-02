# The signed-in account page and account closure (launch-readiness §5 / WS-D).
# Standard REST on a singular resource scoped to current_user — there is no id in
# the path, so there is no cross-tenant surface here at all.
#
# Deletion is irreversible AND cancels money, so it is confirmed by re-entering
# the current password rather than a dialog. The actual work is
# User#close_account! (see User::Closure); this controller only decides what the
# user is shown.
class AccountsController < ApplicationController
  # The password prompt below is one of two credential checks under /account; the
  # attempt budget it shares with the other (Accounts::PasswordsController) and
  # the failure re-render both live in AccountCredentials.
  include AccountCredentials

  rate_limit_account_credentials only: :destroy

  def show
  end

  def destroy
    unless current_user.authenticate(params[:current_password].to_s)
      return render_account(WRONG_PASSWORD_MESSAGE)
    end

    current_user.close_account!
    terminate_session
    redirect_to root_path, notice: "Your account has been deleted.", status: :see_other
  rescue ::Stripe::StripeError, Pay::Error => e
    # Stripe is cancelled before anything is deleted (User::Closure), so a failure
    # here leaves the account completely intact — we would far rather ask the user
    # to retry than half-close it. Log it: a swallowed cancel failure is otherwise
    # invisible to us, and it means a subscription we intended to stop is still
    # live. Same rescue pair as Billing::DowngradesController — cancel_now! wraps
    # Stripe's own errors in Pay::Error.
    Rails.logger.error("[account] closure failed (user=#{current_user.id}): #{e.class}: #{e.message}")
    render_account(
      "We couldn't cancel your subscription, so nothing was deleted. Please try again or email support.",
      status: :service_unavailable)
  end
end
