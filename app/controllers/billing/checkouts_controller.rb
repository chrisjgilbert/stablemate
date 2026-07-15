module Billing
  # Upgrade to Pro — creating a checkout *is* starting a Stripe Checkout session
  # (no custom "upgrade" verb). We redirect the user to Stripe's hosted page;
  # Stripe Tax computes VAT/sales tax there, and no card data ever touches us.
  # The plan only actually changes later, via the verified webhook.
  class CheckoutsController < BaseController
    def create
      # Guard against a second subscription: the Upgrade button is hidden for Pro
      # users, but this action is directly reachable. Without this, an already-Pro
      # user could open a second Checkout and be billed twice (WU-4). subscribed_to_pro?
      # reads Pay's webhook-kept mirror, so a stale client can't spoof it.
      return redirect_back_or_to(billing_subscription_path, alert: "You're already on Pro.") if current_user.subscribed_to_pro?

      price_id = Stablemate.pro_price_id
      return redirect_back_or_to(billing_subscription_path, alert: "Pro plan isn't configured.") if price_id.blank?

      session = current_user.stripe_customer.checkout(
        mode: "subscription",
        line_items: price_id,
        # One Pro subscription per customer.
        subscription_data: {metadata: {user_id: current_user.id}},
        # Stripe Tax (PRD §12): compute VAT/sales tax at checkout.
        automatic_tax: {enabled: true},
        customer_update: {address: "auto"},
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
