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
module Stablemate
  # Max monitors a single user may own (paused monitors still count). (README §2 #7)
  # Env STABLEMATE_MAX_MONITORS_PER_USER unset/0 ⇒ unlimited.
  MAX_MONITORS_PER_USER = ENV.fetch("STABLEMATE_MAX_MONITORS_PER_USER", 0).to_i

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
end

Rails.application.config.x.stablemate.tap do |c|
  c.max_monitors_per_user  = Stablemate::MAX_MONITORS_PER_USER
  c.signup_account_cap     = Stablemate::SIGNUP_ACCOUNT_CAP
  c.detection_interval     = Stablemate::DETECTION_INTERVAL
  c.ping_retention         = Stablemate::PING_RETENTION
  c.default_grace_fraction = Stablemate::DEFAULT_GRACE_FRACTION
end
