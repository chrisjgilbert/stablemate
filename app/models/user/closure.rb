class User
  # Closing an account for good, as an operation owned by the user and reached via
  # user.close_account! (launch-readiness §5 / WS-D). It exists for exactly one
  # reason — the ORDER of its two steps:
  #
  #   1. Cancel Stripe FIRST. A subscription must never outlive its account, and
  #      cancelling before anything is deleted means a Stripe failure aborts with
  #      the account completely intact — never half-closed. The error propagates;
  #      AccountsController turns it into a re-render, not a 500. Doing it first
  #      also defuses Pay's own `after_commit :cancel_active_pay_subscriptions!,
  #      on: [:destroy]` (pay/attributes.rb), which would otherwise fire a live
  #      Stripe call *after* the user row is already gone — and it means that by
  #      the time the rows go, Pay's `before_destroy :cancel_if_active` has
  #      nothing left to cancel. Skipped entirely on a keyless self-host
  #      instance, where there is no Stripe to talk to. All Pay coupling stays on
  #      the User::Subscription concern.
  #   2. Destroy the user. Everything the account owns is declared as a cascade:
  #      sessions, projects → monitors → ping events / incidents / uptime stats /
  #      notifications, the projects' API keys, and the pay_* rows (User::Subscription
  #      re-declares `pay_customers` with the `dependent:` Pay omits). Rails wraps
  #      a destroy and its dependents in one transaction, so the account can never
  #      end up as a user row with no billing records or vice versa.
  #
  # …plus the one row no association reaches: a `waitlist_signups` entry for the
  # same address. Someone who joined the waitlist and was later let in has their
  # email in two tables, and only one of them hangs off the user. The privacy
  # policy promises deletion removes every trace, so the sweep has to be
  # deliberate — matched on the (normalised) address, never anyone else's, and
  # inside the same transaction as the destroy so the account can't half-vanish.
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
