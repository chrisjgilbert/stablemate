module Billing
  # The billing settings screen. Read-only; all state changes go through
  # Checkout/Portal/Downgrade and land back via webhook.
  class SubscriptionsController < BaseController
    def show
      @user = current_user
    end
  end
end
