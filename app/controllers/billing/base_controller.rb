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
    before_action :release_downgrade_lock

    private
      def require_billing_enabled
        render_not_found unless Stablemate.billing_enabled?
      end

      # Self-heal a stale choose-N lock on any billing page load: if the user is
      # back within the Free cap, lift the lock rather than trapping them in a
      # picker they can no longer satisfy. Deletions lift it as they happen
      # (Monitoring::Monitor's after_destroy_commit); this is the backstop for
      # getting back within cap WITHOUT a deletion — chiefly a voluntary downgrade
      # racing its own cancel webhook (M3).
      def release_downgrade_lock
        current_user&.release_downgrade_lock_if_within_cap!
      end
  end
end
