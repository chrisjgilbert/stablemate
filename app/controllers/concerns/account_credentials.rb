# The shared credential surface under /account: the delete confirmation and the
# nested password change. Both re-verify the current password and both answer a
# failure by re-rendering the same page.
#
# Why a bound at all on a SIGNED-IN surface: re-verifying the current password
# makes each form an online password oracle for the one attacker the prompt exists
# to stop — somebody who already holds a stolen session cookie. Unlimited guesses
# hand them the account credential itself (and, since every guess costs a bcrypt
# hash, a cheap CPU amplifier).
#
# ONE budget, keyed by user and shared across both controllers via `scope:`, so
# alternating between the two forms can't double it. Dedicated in-process store so
# the bound holds under the test env's null_store.
module AccountCredentials
  extend ActiveSupport::Concern

  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
  ATTEMPT_LIMIT = 10
  ATTEMPT_WINDOW = 3.minutes
  ATTEMPT_SCOPE = :account_credentials
  THROTTLED_MESSAGE = "Too many attempts. Please try again in a few minutes.".freeze
  # Generic on purpose — never confirm which half of the credential was wrong.
  WRONG_PASSWORD_MESSAGE = "That password is incorrect.".freeze

  class_methods do
    # Callers pass only the actions to guard (`only:`); everything that must match
    # between the two controllers is fixed here, so they can't drift apart into two
    # budgets.
    #
    # Runs after require_authentication (an inherited before_action, so it is
    # registered first), which is what makes Current.user safe to key on.
    def rate_limit_account_credentials(**options)
      rate_limit to: ATTEMPT_LIMIT, within: ATTEMPT_WINDOW,
        by: -> { Current.user.id }, scope: ATTEMPT_SCOPE, store: RATE_LIMIT_STORE,
        with: -> { render_account(THROTTLED_MESSAGE, status: :too_many_requests) },
        **options
    end
  end

  private
    def render_account(alert, status: :unprocessable_entity)
      flash.now[:alert] = alert
      render template: "accounts/show", status: status
    end
end
