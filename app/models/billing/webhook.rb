module Billing
  # Applies a verified, deduplicated Stripe event (issue #19). A thin coordinator:
  # Pay owns subscription bookkeeping (the pay_* tables), so we hand the event to
  # Pay's own handlers, then derive User.plan from the now-current Pay subscription.
  #
  # Only the events that can change a user's plan are handled:
  #   checkout.session.completed, customer.subscription.*, invoice.* (a failed
  #   renewal flips Stripe's subscription to past_due/canceled → plan drops to free
  #   and the over-cap account is locked into choose-5 via the cap logic).
  #
  # The event is already signature-verified and claimed once by the controller, so
  # this runs at most once per delivery.
  class Webhook
    def initialize(event)
      @event = event
    end

    def process!
      pay_process!
      sync_plan!
    end

    private
      # Run Pay's processor for this event type so the pay_* tables reflect Stripe.
      # Pay's handlers are idempotent upserts. We only instrument event types Pay
      # is listening for; others are inert.
      def pay_process!
        type = "stripe.#{@event.type}"
        return unless Pay::Webhooks.delegator.listening?(type)

        Pay::Webhooks.instrument(event: @event, type: type)
      end

      # Recompute plan for the user behind this event from Pay's mirror. The sync
      # is itself idempotent (no-op when plan already matches).
      def sync_plan!
        pay_customer&.owner&.sync_plan_from_subscription!
      end

      # Resolve the Pay::Customer (and thus the User) the event is about, via the
      # Stripe customer id carried on the event object.
      def pay_customer
        stripe_customer_id = @event.data.object.respond_to?(:customer) ? @event.data.object.customer : nil
        return if stripe_customer_id.blank?

        Pay::Customer.find_by(processor: :stripe, processor_id: stripe_customer_id)
      end
  end
end
