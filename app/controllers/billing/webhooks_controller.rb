module Billing
  # Stripe's webhook endpoint — the ONLY writer of User.plan (PRD §12 security).
  #
  # Defence in depth:
  #   * Signature verified against the Stripe signing secret (::Stripe::Webhook
  #     .construct_event) — an unsigned/forged body is rejected with an opaque 400,
  #     no body parsed, no state touched.
  #   * Idempotent: each Stripe event id is claimed once via Billing::ProcessedEvent
  #     (unique index), so a replay of the same delivery is a no-op.
  #   * Public + unauthenticated (Stripe is the caller) and CSRF-exempt, but the
  #     signature *is* the authentication.
  #   * Opaque responses: we never echo why something failed.
  #
  # The actual subscription bookkeeping is Pay's job; we hand the verified event to
  # Pay, then derive User.plan from the updated Pay subscription. Plan is never set
  # from any other surface.
  class WebhooksController < ActionController::Base
    skip_forgery_protection
    before_action :require_billing_enabled

    def create
      event = verified_event

      # Ignore events from the other Stripe mode. A signature alone doesn't prove
      # the event belongs to *this* environment: a test-mode event signed with a
      # shared/leaked secret must never flip a real user's plan. Acknowledge (200)
      # so Stripe stops retrying, but apply nothing. Log it — a genuine event dropped
      # here is the "customer paid but stayed on Free" bug (usually a key/mode
      # misconfiguration), and it must not pass silently.
      unless event.livemode == Stablemate.stripe_livemode?
        Rails.logger.warn("[billing] ignoring webhook #{event.id} (#{event.type}): livemode mismatch (event=#{event.livemode}, app=#{Stablemate.stripe_livemode?})")
        return head :ok
      end

      Billing::ProcessedEvent.record_once(event.id, event_type: event.type) do
        Billing::Webhook.new(event).process!
      end

      head :ok
    rescue ::Stripe::SignatureVerificationError, JSON::ParserError => e
      # The response stays opaque (400, no reason echoed), but log it — a bad
      # signature is usually a wrong/rotated STRIPE_WEBHOOK_SECRET, which we'd
      # otherwise never see.
      Rails.logger.error("[billing] webhook rejected: #{e.class}: #{e.message}")
      head :bad_request
    end

    private
      # Keyless self-host instance: no billing surface. Opaque 404 (not 403) so a
      # probe can't even tell the endpoint exists.
      def require_billing_enabled
        head :not_found unless Stablemate.billing_enabled?
      end

      # Verify the Stripe signature over the raw body. Raises on a bad signature or
      # a missing secret — caught above and surfaced as an opaque 400.
      def verified_event
        ::Stripe::Webhook.construct_event(
          request.body.read,
          request.headers["Stripe-Signature"].to_s,
          Stablemate.stripe_webhook_secret.to_s
        )
      end
  end
end
