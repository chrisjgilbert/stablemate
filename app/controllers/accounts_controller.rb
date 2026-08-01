# The signed-in account page and account closure (launch-readiness §5 / WS-D).
# Standard REST on a singular resource scoped to current_user — there is no id in
# the path, so there is no cross-tenant surface here at all.
#
# Deletion is irreversible AND cancels money, so it is confirmed by re-entering
# the current password rather than a dialog. The actual work is
# User#close_account! (see User::Closure); this controller only decides what the
# user is shown.
class AccountsController < ApplicationController
  # Both credential checks under /account — this delete confirmation and the
  # nested password change — re-verify the current password, which makes each an
  # online password oracle for the one attacker that prompt exists to stop:
  # somebody who already holds a stolen session cookie. Unlimited guesses hand
  # them the account credential itself (and, since every guess costs a bcrypt
  # hash, a cheap CPU amplifier). The unauthenticated credential surfaces are
  # already bounded (SessionsController, PasswordsController, RegistrationsController);
  # holding a cookie must not buy an exemption.
  #
  # ONE budget, keyed by user and shared across both controllers via `scope:`, so
  # alternating between the two forms can't double it. Dedicated in-process store
  # so the bound holds under the test env's null_store, mirroring
  # PingsController/RegistrationsController.
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
  CREDENTIAL_ATTEMPT_LIMIT = 10
  CREDENTIAL_ATTEMPT_WINDOW = 3.minutes
  CREDENTIAL_ATTEMPT_SCOPE = :account_credentials
  THROTTLED_MESSAGE = "Too many attempts. Please try again in a few minutes.".freeze

  # Runs after require_authentication (an inherited before_action, so it is
  # registered first), which is what makes Current.user safe to key on here.
  rate_limit to: CREDENTIAL_ATTEMPT_LIMIT, within: CREDENTIAL_ATTEMPT_WINDOW, only: :destroy,
    by: -> { Current.user.id }, scope: CREDENTIAL_ATTEMPT_SCOPE, store: RATE_LIMIT_STORE,
    with: -> { render_show(status: :too_many_requests, alert: THROTTLED_MESSAGE) }

  def show
  end

  def destroy
    unless current_user.authenticate(params[:current_password].to_s)
      return render_show(status: :unprocessable_entity, alert: "That password is incorrect.")
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
    render_show(status: :service_unavailable,
      alert: "We couldn't cancel your subscription, so nothing was deleted. Please try again or email support.")
  end

  private
    def render_show(status:, alert:)
      flash.now[:alert] = alert
      render :show, status: status
    end
end
