module Billing
  # Shared base for the authenticated billing UI controllers (checkout, portal,
  # downgrade, subscription). Two invariants for every billing action:
  #
  #   * the user is signed in (inherited from ApplicationController), and
  #   * billing is enabled (Stripe keys present). When it isn't — the self-host
  #     default — the whole namespace 404s, so a keyless instance has no billing
  #     surface and the UI never links here.
  #
  # The webhook endpoint is deliberately NOT a child of this (it's Stripe-facing,
  # unauthenticated) but enforces the same billing gate itself.
  class BaseController < ApplicationController
    before_action :require_billing_enabled

    private
      def require_billing_enabled
        render_not_found unless Stablemate.billing_enabled?
      end
  end
end
