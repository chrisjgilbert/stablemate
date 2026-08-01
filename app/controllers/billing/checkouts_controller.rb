module Billing
  # Upgrade to Pro — creating a checkout *is* starting a Stripe Checkout session
  # (no custom "upgrade" verb). We redirect the user to Stripe's hosted page;
  # Stripe Tax computes VAT/sales tax there, and no card data ever touches us.
  # The plan only actually changes later, via the verified webhook.
  class CheckoutsController < BaseController
    def create
      # Guard against a second subscription: the Upgrade button is hidden for Pro
      # users, but this action is directly reachable. Without this, an already-Pro
      # user could open a second Checkout and be billed twice (WU-4).
      # live_pro_subscription? reads Pay's webhook-kept mirror (so a stale client
      # can't spoof it) and counts every non-terminal subscription — including a
      # past_due one, whose plan has already dropped to Free but whose dunning retry
      # can still succeed days later (F5).
      return redirect_back_or_to(billing_subscription_path, alert: "You're already on Pro.") if current_user.live_pro_subscription?

      price_id = Stablemate.pro_price_id
      return redirect_back_or_to(billing_subscription_path, alert: "Pro plan isn't configured.") if price_id.blank?

      # Past the guard, the only Pro subscription that can still exist is an
      # `incomplete` one — a first payment that was never authenticated, which we
      # deliberately let the user retry rather than blocking them for the ~23h
      # Stripe takes to expire it. Cancel it before opening the new session: Stripe
      # emails that customer a link straight back to the old invoice, so leaving it
      # alive means "retry, then complete the original" ends in two active
      # subscriptions. It has never been charged, so this costs the user nothing.
      current_user.cancel_pro_subscription!

      session = current_user.stripe_customer.checkout(
        mode: "subscription",
        line_items: price_id,
        # One Pro subscription per customer.
        subscription_data: { metadata: { user_id: current_user.id } },
        # Stripe Tax (PRD §12): compute VAT/sales tax at checkout.
        automatic_tax: { enabled: true },
        customer_update: { address: "auto" },
        success_url: billing_subscription_url,
        cancel_url: billing_subscription_url
      )

      redirect_to session.url, allow_other_host: true, status: :see_other
    rescue ::Stripe::StripeError, Pay::Error => e
      # Pay raises ::Stripe::StripeError straight through for Checkout, but wraps
      # other failures in Pay::Error — catch both so no Stripe hiccup 500s the user.
      # Log it: the user gets a retry message, but a swallowed billing failure would
      # otherwise be invisible to us.
      Rails.logger.error("[billing] checkout failed (user=#{current_user.id}): #{e.class}: #{e.message}")
      redirect_back_or_to billing_subscription_path, alert: "Couldn't start checkout. Please try again."
    end
  end
end
