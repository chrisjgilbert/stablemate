module Billing
  # Stripe's webhook endpoint — the ONLY writer of User.plan (PRD §12 security).
  # Public, unauthenticated and CSRF-exempt, but the signature *is* the
  # authentication; each event id is claimed once via Billing::ProcessedEvent, so a
  # replay is a no-op. Responses are opaque — we never echo why something failed.
  class WebhooksController < ActionController::Base
    skip_forgery_protection
    before_action :require_billing_enabled

    def create
      event = verified_event

      # A signature alone doesn't prove the event belongs to *this* environment: a
      # test-mode event signed with a shared/leaked secret must never flip a real
      # user's plan. Acknowledge (200) so Stripe stops retrying, but apply nothing.
      # Log it — a genuine event dropped here is the "customer paid but stayed on
      # Free" bug, and it must not pass silently.
      unless event.livemode == Stablemate.stripe_livemode?
        Rails.logger.warn("[billing] ignoring webhook #{event.id} (#{event.type}): livemode mismatch (event=#{event.livemode}, app=#{Stablemate.stripe_livemode?})")
        return head :ok
      end

      Billing::ProcessedEvent.record_once(event.id, event_type: event.type) do
        Billing::Webhook.new(event).process!
      end

      head :ok
    rescue ::Stripe::SignatureVerificationError, JSON::ParserError => e
      # The response stays opaque, but log it — a bad signature is usually a
      # wrong/rotated STRIPE_WEBHOOK_SECRET, which we'd otherwise never see.
      Rails.logger.error("[billing] webhook rejected: #{e.class}: #{e.message}")
      head :bad_request
    end

    private
      # Opaque 404 (not 403) so a probe can't even tell the endpoint exists.
      def require_billing_enabled
        head :not_found unless Stablemate.billing_enabled?
      end

      def verified_event
        ::Stripe::Webhook.construct_event(
          request.body.read,
          request.headers["Stripe-Signature"].to_s,
          Stablemate.stripe_webhook_secret.to_s
        )
      end
  end
end
