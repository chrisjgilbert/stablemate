module Billing
  # Manage card / view invoices — creating a portal session *is* opening Stripe's
  # hosted Customer Portal. We build no card forms or invoice UI; we just mint the
  # session and redirect. Any cancellation done in the Portal returns to us by
  # webhook (the involuntary-downgrade path).
  class PortalSessionsController < BaseController
    def create
      session = current_user.stripe_customer.billing_portal(
        return_url: billing_subscription_url
      )
      redirect_to session.url, allow_other_host: true, status: :see_other
    rescue ::Stripe::StripeError, Pay::Error
      # Catch Pay's wrapped errors too (see CheckoutsController) so a Stripe hiccup
      # surfaces a retry message instead of an unhandled 500.
      redirect_back_or_to billing_subscription_path, alert: "Couldn't open the billing portal. Please try again."
    end
  end
end
