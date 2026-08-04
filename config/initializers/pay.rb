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

# Hand Stripe its keys from our single config-gate source. Pay has no key
# setters — `Pay::Stripe.public_key/private_key/signing_secret` are *readers* that
# resolve via `find_value_by_name(:stripe, …)`, i.e. ENV["STRIPE_PUBLIC_KEY"] /
# ["STRIPE_PRIVATE_KEY"] / ["STRIPE_SIGNING_SECRET"] (then Rails credentials). So
# we bridge our own names (Stablemate.stripe_*) onto the ones Pay reads, keeping a
# single place keys live. `||=` so an operator who sets Pay's native names wins.
# Guarded by billing_enabled? so a keyless (self-host) instance never touches the
# Stripe SDK and Pay stays dormant.
if Stablemate.billing_enabled?
  ENV["STRIPE_PUBLIC_KEY"] ||= Stablemate.stripe_publishable_key
  ENV["STRIPE_PRIVATE_KEY"] ||= Stablemate.stripe_secret_key
  ENV["STRIPE_SIGNING_SECRET"] ||= Stablemate.stripe_webhook_secret
end

# Never let Pay mount its own routes. Pay still defaults automount_routes to true
# (checked again on 11.7), which mounts the engine at /pay and hands us two
# surfaces we never asked for:
#
#   * POST /pay/webhooks/stripe — a SECOND Stripe webhook endpoint. It verifies
#     against the same signing secret, so it looks legitimate, but it bypasses
#     Billing::ProcessedEvent idempotency, the livemode gate and the plan sync in
#     Billing::WebhooksController. Point Stripe at it by accident and a paying
#     customer stays on Free. Billing::WebhooksController is the only Stripe
#     entry point (PRD §12: one writer of User.plan).
#   * GET /pay/payments/:id — unauthenticated, and the rendered page embeds the
#     PaymentIntent's client_secret. We use Stripe Checkout, so we never need it.
#
# This must be set before Pay::Engine's "pay.processors" initializer, which is
# where the mount is appended — app config/initializers run first (they land
# ~index 110 vs the engine's ~372), so here is early enough.
Pay.automount_routes = false

Pay.setup do |config|
  config.application_name = "Stablemate"
  # NO support_email. Pay resolves its from-address as
  # `Pay.support_email || ::ApplicationMailer.default_params[:from]`, so setting
  # it here doesn't add an address — it OVERRIDES ours, with a literal domain a
  # self-hoster doesn't own. Leaving it unset makes Pay follow
  # STABLEMATE_MAIL_FROM like every other mailer (MailFromTest pins this).

  # We have exactly one paid product — Pro. Naming every subscription "pro" lets
  # User::Subscription#subscribed_to_pro? ask Pay a single, plan-agnostic question.
  config.default_product_name = "pro"

  # No stock Pay emails (launch-readiness decision D9). Pay's customer-facing
  # mailers default ON and are entirely unconfigured — unbranded copy, our support
  # address, never reviewed. This switches off all of them: receipt,
  # refund, payment_failed, payment_action_required, subscription_renewing,
  # subscription_trial_will_end and subscription_trial_ended.
  #
  # Beyond the copy, `payment_failed` is the dangerous one: Pay's handler calls
  # `deliver_now` *inside* our Billing::ProcessedEvent idempotency transaction, so
  # an SMTP failure raises through the webhook (production raises delivery errors
  # since F1), rolls the ledger claim back, and has Stripe retry the whole event —
  # re-sending the mail each time. Every message we do send is our own, queued, and
  # sent after commit.
  #
  # Reversing this is one line: drop it (or set `config.send_emails = true`) and
  # re-enable per-email with `config.emails.receipt = true` etc. — but brand and
  # review the templates first, and move the payment_failed delivery off the
  # webhook's transaction.
  config.send_emails = false

  # Only register the Stripe backend when keys are present; otherwise Pay has no
  # processor and the billing surface stays dormant. Pay::Stripe.setup reads the
  # keys bridged above and sets ::Stripe.api_key itself.
  config.enabled_processors = Stablemate.billing_enabled? ? %i[stripe] : []
end

# Don't eager-load the Stripe SDK into a keyless instance.
#
# stripe's railtie does `config.eager_load_namespaces << Stripe` unconditionally,
# so production eager-loads all 1039 of its files on every boot — including the
# self-host default, where `enabled_processors` is empty, the Billing:: routes
# 404, and nothing can reach a Stripe constant. Measured on a keyless production
# boot: ~320ms and ~34MB RSS for code that is never called.
#
# Keep the eager load when keys ARE present: Stripe's resources are plain
# autoloads, and resolving them lazily inside a forked Puma worker would pay the
# cost per worker rather than once, pre-fork and copy-on-write shared.
#
# NOT `gem "stripe", require: false` — Pay never requires the SDK itself
# (`grep -rn 'require "stripe"'` in pay is empty); it relies on Bundler.require,
# so that would break the hosted instance outright.
unless Stablemate.billing_enabled?
  Rails.application.config.eager_load_namespaces.delete(Stripe)
end
