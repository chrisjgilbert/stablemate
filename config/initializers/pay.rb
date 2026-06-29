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

# Hand Stripe its keys from our single config-gate source. Pay 8 has no key
# setters — `Pay::Stripe.public_key/private_key/signing_secret` are *readers* that
# resolve via `find_value_by_name(:stripe, …)`, i.e. ENV["STRIPE_PUBLIC_KEY"] /
# ["STRIPE_PRIVATE_KEY"] / ["STRIPE_SIGNING_SECRET"] (then Rails credentials). So
# we bridge our own names (Stablemate.stripe_*) onto the ones Pay reads, keeping a
# single place keys live. `||=` so an operator who sets Pay's native names wins.
# Guarded by billing_enabled? so a keyless (self-host) instance never touches the
# Stripe SDK and Pay stays dormant.
if Stablemate.billing_enabled?
  ENV["STRIPE_PUBLIC_KEY"]     ||= Stablemate.stripe_publishable_key
  ENV["STRIPE_PRIVATE_KEY"]    ||= Stablemate.stripe_secret_key
  ENV["STRIPE_SIGNING_SECRET"] ||= Stablemate.stripe_webhook_secret
end

Pay.setup do |config|
  config.application_name = "Stablemate"
  config.support_email    = "support@stablemate.dev"

  # We have exactly one paid product — Pro. Naming every subscription "pro" lets
  # User::Subscription#subscribed_to_pro? ask Pay a single, plan-agnostic question.
  config.default_product_name = "pro"

  # Only register the Stripe backend when keys are present; otherwise Pay has no
  # processor and the billing surface stays dormant. Pay::Stripe.setup reads the
  # keys bridged above and sets ::Stripe.api_key itself.
  config.enabled_processors = Stablemate.billing_enabled? ? %i[stripe] : []
end
