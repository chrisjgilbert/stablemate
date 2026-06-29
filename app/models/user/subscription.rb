class User
  # Hosted-tier subscription state, wrapping the Pay gem (issue #19). We never
  # hand-roll subscription state — Pay owns the pay_* tables and Stripe is the
  # source of truth, reached only through verified webhooks.
  #
  # Crucial invariant: `User.plan` is *derived* from the active Pay subscription
  # and is rewritten ONLY by #sync_plan_from_subscription!, which is called only
  # from Billing::WebhooksController after Stripe's signature is verified. No
  # controller, view, or client input ever sets `plan` directly. (PRD §12 security.)
  module Subscription
    extend ActiveSupport::Concern

    PRO_PRODUCT = "pro".freeze

    included do
      # Make the User a Pay billable: pay_customers / subscriptions / charges.
      pay_customer
    end

    # Find or create the user's default Stripe customer, ready for Checkout/Portal.
    def stripe_customer
      set_payment_processor(:stripe) unless payment_processor&.processor == "stripe"
      payment_processor
    end

    # Does Stripe currently consider this user actively subscribed to Pro? Reads
    # Pay's local mirror (kept current by webhooks) — not the client.
    def subscribed_to_pro?
      payment_processor&.subscribed?(name: PRO_PRODUCT) || false
    end

    # Recompute `plan` from the Pay subscription mirror and persist it. THE ONLY
    # writer of `plan`. Returns true when the plan actually changed.
    #   active Pro subscription ⇒ "pro";  none/cancelled ⇒ "free".
    #
    # Side effects keep monitors consistent with the new cap:
    #   * dropping to Free over the cap (involuntary downgrade — card failure or
    #     Portal cancel) immediately suspends the over-cap monitors so there's
    #     never silent free monitoring;
    #   * returning to Pro restores previously plan-suspended monitors (PRD §5.6:
    #     "if they re-upgrade later, suspended monitors can be reactivated"), up to
    #     the Pro cap.
    def sync_plan_from_subscription!
      target = subscribed_to_pro? ? Plan::PRO : Plan::FREE
      changed = plan != target
      update!(plan: target) if changed

      if target == Plan::FREE
        Downgrade.new(self).enforce_free_cap!
      else
        restore_suspended_monitors!
      end

      changed
    end

    # The gated "choose your 5" downgrade (PRD §5.6). Suspends the unchosen
    # monitors and cancels Stripe; the plan flip itself arrives by webhook.
    def downgrade_to_free!(keep_ids: [])
      Downgrade.new(self).to_free!(keep_ids: keep_ids)
    end

    # Cancel the user's active Pro subscription at Stripe (e.g. on downgrade). The
    # plan flip is left to the resulting webhook (the only writer of plan), so the
    # client and server can never drift. Pay coupling lives here, not in callers.
    def cancel_pro_subscription!
      pro_subscription&.cancel_now!
    end

    # Reactivate plan-suspended monitors (oldest first) up to the available Pro
    # slots. Reached on a re-upgrade. Each monitor re-evaluates its own heartbeat.
    def restore_suspended_monitors!
      slots = remaining_monitor_slots
      return if slots <= 0

      scope = monitors.where(status: "suspended").order(:created_at)
      scope = scope.limit(slots) unless slots == Float::INFINITY
      scope.find_each(&:reactivate!)
    end

    # True when the account is over the Free cap while on (or dropping to) Free —
    # i.e. it owes a choose-5 decision before normal use resumes.
    def must_choose_downgrade?
      free? && over_free_cap_by.positive?
    end

    private
      # The user's active Pro subscription per Pay's mirror (active scope, not just
      # newest-created), so we never act on a stale/canceled row.
      def pro_subscription
        payment_processor&.subscriptions&.active&.find_by(name: PRO_PRODUCT)
      end
  end
end
