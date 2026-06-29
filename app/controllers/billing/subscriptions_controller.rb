module Billing
  # The billing settings screen (hosted tier only). Shows the current plan, the
  # upgrade affordance for Free users, and — for Pro users — links to the Stripe
  # Customer Portal (card/invoices) and the gated in-app downgrade. Read-only; all
  # state changes go through Checkout/Portal/Downgrade and land back via webhook.
  class SubscriptionsController < BaseController
    def show
      @user = current_user
    end
  end
end
