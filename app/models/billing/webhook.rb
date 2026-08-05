module Billing
  # Applies a verified, deduplicated Stripe event. Pay owns subscription
  # bookkeeping (the pay_* tables), so we hand the event to Pay's own handlers,
  # then derive User.plan from the now-current Pay subscription.
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
      # Pay's handlers are idempotent upserts. We only instrument event types Pay
      # is listening for; others are inert.
      def pay_process!
        type = "stripe.#{@event.type}"
        return unless Pay::Webhooks.delegator.listening?(type)

        Pay::Webhooks.instrument(event: @event, type: type)
      end

      def sync_plan!
        pay_customer&.owner&.sync_plan_from_subscription!
      end

      def pay_customer
        stripe_customer_id = @event.data.object.respond_to?(:customer) ? @event.data.object.customer : nil
        return if stripe_customer_id.blank?

        Pay::Customer.find_by(processor: :stripe, processor_id: stripe_customer_id)
      end
  end
end
