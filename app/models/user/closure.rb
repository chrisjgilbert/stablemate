class User
  # Closing an account for good, reached via user.close_account! (WS-D). It exists
  # for the ORDER of its steps:
  #
  #   1. Cancel Stripe FIRST, so a Stripe failure aborts with the account intact
  #      rather than half-closed (AccountsController re-renders the error). It also
  #      defuses Pay's own `after_commit :cancel_active_pay_subscriptions!,
  #      on: [:destroy]`, which would otherwise fire a live Stripe call after the
  #      user row is gone. Skipped on a keyless self-host instance.
  #   2. Destroy the user. Everything the account owns cascades, pay_* rows
  #      included (User::Subscription re-declares `pay_customers` with the
  #      `dependent:` Pay omits), in one transaction.
  #   3. Sweep the one row no association reaches — a waitlist_signups entry for
  #      the same address, left behind by someone who joined the waitlist and was
  #      later let in. The privacy policy promises deletion removes every trace,
  #      so it runs inside the same transaction.
  class Closure
    def initialize(user)
      @user = user
    end

    def close_account!
      @user.cancel_pro_subscription! if Stablemate.billing_enabled?

      User.transaction do
        WaitlistSignup.where(email_address: @user.email_address).delete_all
        @user.destroy!
      end
    end
  end
end
