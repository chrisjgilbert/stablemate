# Pay is the only subscription-state layer — we don't hand-roll it. It stays
# dormant unless Stripe keys are configured, which is the self-host default: no
# keys ⇒ Pay tables stay empty and everyone is Free.

# Initializers load alphabetically, so stablemate.rb hasn't run yet — load it now
# for billing_enabled? below. It self-guards against the second load.
require_relative "stablemate"

# Pay has no key setters: `Pay::Stripe.public_key` and friends are readers that
# resolve from ENV["STRIPE_PUBLIC_KEY"] / ["STRIPE_PRIVATE_KEY"] /
# ["STRIPE_SIGNING_SECRET"], then Rails credentials. Bridge our names onto the
# ones Pay reads so there is a single place keys live. `||=` so an operator who
# sets Pay's native names wins.
if Stablemate.billing_enabled?
  ENV["STRIPE_PUBLIC_KEY"] ||= Stablemate.stripe_publishable_key
  ENV["STRIPE_PRIVATE_KEY"] ||= Stablemate.stripe_secret_key
  ENV["STRIPE_SIGNING_SECRET"] ||= Stablemate.stripe_webhook_secret
end

# Never let Pay mount its own routes (it still defaults to true on 11.7). The
# engine would hand us two surfaces we never asked for:
#
#   * POST /pay/webhooks/stripe — a SECOND Stripe webhook endpoint that bypasses
#     Billing::ProcessedEvent idempotency, the livemode gate and the plan sync.
#   * GET /pay/payments/:id — unauthenticated, and embeds the PaymentIntent's
#     client_secret.
#
# Must be set before Pay::Engine's "pay.processors" initializer appends the mount;
# app initializers run first, so here is early enough.
Pay.automount_routes = false

Pay.setup do |config|
  config.application_name = "Stablemate"
  # NO support_email: Pay resolves its from-address as
  # `Pay.support_email || ::ApplicationMailer.default_params[:from]`, so setting it
  # here overrides ours with a domain a self-hoster doesn't own.

  # Naming every subscription "pro" lets User::Subscription#subscribed_to_pro? ask
  # Pay a single, plan-agnostic question.
  config.default_product_name = "pro"

  # No stock Pay emails: they default on, are entirely unconfigured, and
  # `payment_failed` is actively dangerous — Pay's handler calls `deliver_now`
  # *inside* our Billing::ProcessedEvent idempotency transaction, so an SMTP
  # failure rolls the ledger claim back and has Stripe retry the whole event,
  # re-sending the mail each time. To re-enable: brand the templates first, and
  # move the payment_failed delivery off the webhook's transaction.
  config.send_emails = false

  # Without keys Pay has no processor and the billing surface stays dormant.
  config.enabled_processors = Stablemate.billing_enabled? ? %i[stripe] : []
end
