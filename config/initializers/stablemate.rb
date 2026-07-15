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
  MAX_MONITORS_PER_USER = ENV.fetch("STABLEMATE_MAX_MONITORS_PER_USER", 0).to_i

  FREE_PLAN_MONITOR_LIMIT = 5
  PRO_PLAN_MONITOR_LIMIT = 100

  SIGNUP_ACCOUNT_CAP = ENV.fetch("STABLEMATE_SIGNUP_ACCOUNT_CAP", 0).to_i

  DETECTION_INTERVAL = 30.seconds

  PING_RETENTION = 90.days

  DEFAULT_GRACE_FRACTION = 0.15

  def self.monitor_cap_enabled?
    MAX_MONITORS_PER_USER.positive?
  end

  def self.signup_cap_enabled?
    SIGNUP_ACCOUNT_CAP.positive?
  end

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

  def self.stripe_livemode?
    stripe_secret_key.to_s.start_with?("sk_live_", "rk_live_")
  end

  # The Stripe Price ID for an upgrade. Monthly today; annual is a future seam.
  def self.pro_price_id(annual: false)
    annual ? stripe_price_id_pro_annual : stripe_price_id_pro
  end

  def self.stripe_price_id_pro
    ENV["STRIPE_PRICE_ID_PRO"].presence ||
      Rails.application.credentials.dig(:stripe, :price_id_pro)
  end

  def self.stripe_price_id_pro_annual
    ENV["STRIPE_PRICE_ID_PRO_ANNUAL"].presence ||
      Rails.application.credentials.dig(:stripe, :price_id_pro_annual)
  end

  # Slack incoming-webhook URL for team alerts (e.g. new sign-ups). Config-gated
  # like the launch cap — unset by default, so self-hosters never see it; the
  # managed instance turns it on via env or credentials.
  def self.slack_webhook_url
    ENV["SLACK_WEBHOOK_URL"].presence ||
      Rails.application.credentials.dig(:slack, :webhook_url)
  end

  def self.slack_notifications_enabled?
    slack_webhook_url.present?
  end
end

Rails.application.config.x.stablemate.tap do |c|
  c.max_monitors_per_user = Stablemate::MAX_MONITORS_PER_USER
  c.signup_account_cap = Stablemate::SIGNUP_ACCOUNT_CAP
  c.detection_interval = Stablemate::DETECTION_INTERVAL
  c.ping_retention = Stablemate::PING_RETENTION
  c.default_grace_fraction = Stablemate::DEFAULT_GRACE_FRACTION
end
