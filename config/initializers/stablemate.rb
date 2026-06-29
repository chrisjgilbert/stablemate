# Stablemate cost-control & behaviour constants — the single source of truth.
#
# Tests assert behaviour *relative to* these constants (never hard-coded
# numbers), so changing a value here doesn't break the suite. See
# docs/specs/README.md §"Money / cost-control constants".
#
# Reached via Rails.application.config.x.stablemate.<name> or the Stablemate
# module constants below (whichever reads more naturally at the call site).
#
# CAPS ARE CONFIG-GATED AND DEFAULT TO OFF (issue #16). A self-hoster runs with
# no per-user monitor cap and no global signup cap/waitlist; the managed instance
# switches them on via env. Both caps follow the same rule:
#
#   unset or 0  ⇒  unlimited (the cap is OFF)
#   a positive  ⇒  that integer is the cap (the cap is ON)
#
# Use the query helpers below (`monitor_cap_enabled?`, `signup_cap_enabled?`)
# rather than re-deriving "is 0 ⇒ unlimited" at every call site.
# Loaded both in Rails' normal initializer pass and (earlier) via require_relative
# from pay.rb, which needs the config-gate before its own initializer runs. Guard
# so the constants are defined exactly once regardless of order.
return if defined?(Stablemate) && Stablemate.respond_to?(:billing_enabled?)

module Stablemate
  # Max monitors a single user may own (paused monitors still count). (README §2 #7)
  # Env STABLEMATE_MAX_MONITORS_PER_USER unset/0 ⇒ unlimited.
  MAX_MONITORS_PER_USER = ENV.fetch("STABLEMATE_MAX_MONITORS_PER_USER", 0).to_i

  # Hosted-tier plan caps (issue #19). When billing is enabled the per-user
  # monitor cap is *plan-derived* (these win over MAX_MONITORS_PER_USER); when
  # billing is OFF (self-host) #16's env-driven cap stands unchanged.
  FREE_PLAN_MONITOR_LIMIT = 5
  PRO_PLAN_MONITOR_LIMIT  = 100

  # Stripe Price ID for the Pro plan — configuration, never a hardcoded £ amount
  # (PRD §8 Q9: the £ number is undecided, the shape — 100 monitors, no trial —
  # is decided). Annual is a clean seam: set STRIPE_PRICE_ID_PRO_ANNUAL to a
  # second Price ID later; V1 ships monthly-only.
  STRIPE_PRICE_ID_PRO         = ENV["STRIPE_PRICE_ID_PRO"].presence
  STRIPE_PRICE_ID_PRO_ANNUAL  = ENV["STRIPE_PRICE_ID_PRO_ANNUAL"].presence

  # Global account cap; raised manually to re-open signups. (README §2 #7)
  # Env STABLEMATE_SIGNUP_ACCOUNT_CAP unset/0 ⇒ unlimited ⇒ signups always open.
  SIGNUP_ACCOUNT_CAP = ENV.fetch("STABLEMATE_SIGNUP_ACCOUNT_CAP", 0).to_i

  # Detection sweep cadence — the recurring DetectMissedPingsJob interval. (README §2 #1)
  DETECTION_INTERVAL     = 30.seconds

  # How long raw PingEvents are kept before pruning. (README §4)
  PING_RETENTION         = 90.days

  # Gem-derived grace = this fraction of the interval (min 5 minutes). (README §4)
  DEFAULT_GRACE_FRACTION = 0.15

  # Whether a finite per-user monitor cap is configured. False ⇒ unlimited.
  def self.monitor_cap_enabled?
    MAX_MONITORS_PER_USER.positive?
  end

  # Whether a finite global signup cap is configured. False ⇒ signups always
  # open, no waitlist.
  def self.signup_cap_enabled?
    SIGNUP_ACCOUNT_CAP.positive?
  end

  # Hosted-tier billing is enabled iff the full Stripe key set is configured —
  # publishable + secret AND the webhook signing secret. The webhook secret is
  # required, not optional: without it every Stripe delivery fails signature
  # verification and User.plan never updates, so a customer could pay and stay on
  # Free forever. We'd rather keep billing fully OFF (the self-host default: no
  # billing routes/UI, caps per #16, Pay tables unused, no `suspended` monitor)
  # than half-on and unreconcilable. (PRD §12 config-gate.)
  def self.billing_enabled?
    stripe_publishable_key.present? && stripe_secret_key.present? && stripe_webhook_secret.present?
  end

  def self.stripe_publishable_key
    ENV["STRIPE_PUBLISHABLE_KEY"].presence ||
      Rails.application.credentials.dig(:stripe, :publishable_key)
  end

  def self.stripe_secret_key
    ENV["STRIPE_SECRET_KEY"].presence ||
      Rails.application.credentials.dig(:stripe, :secret_key)
  end

  def self.stripe_webhook_secret
    ENV["STRIPE_WEBHOOK_SECRET"].presence ||
      Rails.application.credentials.dig(:stripe, :webhook_secret)
  end

  # Which Stripe mode this instance runs in, derived from the secret-key prefix
  # (sk_live_… ⇒ live, otherwise test). Used to reject webhook events from the
  # other mode even when their signature verifies.
  def self.stripe_livemode?
    stripe_secret_key.to_s.start_with?("sk_live_")
  end

  # The Stripe Price ID for an upgrade. Monthly today; annual is a future seam.
  def self.pro_price_id(annual: false)
    annual ? STRIPE_PRICE_ID_PRO_ANNUAL : STRIPE_PRICE_ID_PRO
  end
end

Rails.application.config.x.stablemate.tap do |c|
  c.max_monitors_per_user  = Stablemate::MAX_MONITORS_PER_USER
  c.signup_account_cap     = Stablemate::SIGNUP_ACCOUNT_CAP
  c.detection_interval     = Stablemate::DETECTION_INTERVAL
  c.ping_retention         = Stablemate::PING_RETENTION
  c.default_grace_fraction = Stablemate::DEFAULT_GRACE_FRACTION
end
