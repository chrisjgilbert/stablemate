class User
  # Closing an account for good, as an operation owned by the user and reached via
  # user.close_account! (launch-readiness §5 / WS-D). It is more than a bare
  # `destroy!` for two reasons, and the ORDER of the three steps is the whole
  # point:
  #
  #   1. Cancel Stripe FIRST. A subscription must never outlive its account, and
  #      cancelling before anything is deleted means a Stripe failure aborts with
  #      the account completely intact — never half-closed. The error propagates;
  #      AccountsController turns it into a re-render, not a 500. Doing it first
  #      also defuses Pay's own `after_commit :cancel_active_pay_subscriptions!,
  #      on: [:destroy]` (pay/attributes.rb), which would otherwise fire a live
  #      Stripe call *after* the user row is already gone.
  #   2. Destroy the pay_customers EXPLICITLY. Pay declares no `dependent:`
  #      option on `has_many :pay_customers` (verified in pay 11.7), so a bare
  #      user destroy leaves every pay_* row behind with a nil owner — and an
  #      orphaned Pay::Customer is a live hazard for incoming webhooks. Each
  #      Pay::Customer *does* cascade to its own subscriptions / charges /
  #      payment methods, so taking the customers down is sufficient.
  #   3. Destroy the user. Everything else is already declared: sessions,
  #      projects → monitors → ping events / incidents / uptime stats /
  #      notifications, and the projects' API keys.
  #
  # Steps 2 and 3 share one transaction, so the account can never end up as a
  # user row with no billing records or vice versa.
  class Closure
    def initialize(user)
      @user = user
    end

    def close_account!
      cancel_subscription!

      @user.transaction do
        @user.pay_customers.destroy_all
        @user.destroy!
      end
    end

    private
      # All Pay coupling stays on the Subscription concern. Skipped entirely on a
      # keyless self-host instance, where there is no Stripe to talk to.
      # cancel_pro_subscription! cancels every still-billable Pro subscription,
      # so by the time step 2 destroys the rows Pay's own
      # `before_destroy :cancel_if_active` has nothing left to cancel.
      def cancel_subscription!
        return unless Stablemate.billing_enabled?

        @user.cancel_pro_subscription!
      end
  end
end
