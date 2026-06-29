# Pay configuration (issue #19, hosted-tier billing).
#
# Pay is the only subscription-state layer — we don't hand-roll it. It is dormant
# unless Stripe keys are configured (Stablemate.billing_enabled?), which is the
# self-host default: no keys ⇒ Pay tables stay empty and everyone is Free.
#
# We feed Stripe's credentials from the single Stablemate source of truth (env or
# Rails credentials) rather than Pay's own ENV names, so there is exactly one
# place keys live. Stripe Tax is enabled at checkout from the Checkouts controller.
#
# Initializers load alphabetically, so `stablemate.rb` (which defines the
# Stablemate config-gate) hasn't run yet — load it now so billing_enabled? is
# available here. stablemate.rb self-guards against the redundant second load.
require_relative "stablemate"

Pay.setup do |config|
  config.application_name = "Stablemate"
  config.support_email    = "support@stablemate.dev"

  # We have exactly one paid product — Pro. Naming every subscription "pro" lets
  # User::Subscription#subscribed_to_pro? ask Pay a single, plan-agnostic question.
  config.default_product_name = "pro"

  # Only register the Stripe backend when keys are present; otherwise Pay has no
  # processor and the billing surface stays dormant.
  config.enabled_processors = Stablemate.billing_enabled? ? %i[stripe] : []
end

# Hand Stripe its keys from our config gate. Guarded so a keyless (self-host)
# instance never touches the Stripe SDK.
if Stablemate.billing_enabled?
  Stripe.api_key = Stablemate.stripe_secret_key
  Pay::Stripe.public_key      = Stablemate.stripe_publishable_key
  Pay::Stripe.private_key     = Stablemate.stripe_secret_key
  Pay::Stripe.signing_secret  = Stablemate.stripe_webhook_secret
end
