class User
  # Plan-derived monitor capacity.
  #
  # Two regimes, chosen by the billing config-gate (issue #19):
  #
  #   * billing ENABLED (managed instance, Stripe keys set): the cap is
  #     *plan-derived* — Free = 5, Pro = 100 — keyed off `plan`, which is itself
  #     only ever changed by a verified Stripe webhook (User::Subscription).
  #   * billing DISABLED (self-host default, issue #16): the env-driven cap
  #     stands unchanged — unset/0 ⇒ unlimited.
  #
  # `suspended` monitors (plan downgrade, PRD §3.3) never count toward the cap;
  # `paused` ones still do (locked decision #8). Backs
  # Monitoring::Monitor#within_monitor_cap.
  module Plan
    extend ActiveSupport::Concern

    FREE = "free".freeze
    PRO  = "pro".freeze

    def free? = plan == FREE
    def pro?  = plan == PRO

    # Whether this user could move to Pro right now — used by every "Upgrade"
    # CTA (the at-cap nudge, the pricing page) so they can't drift on the
    # eligibility rule. False on a keyless self-host instance (issue #19):
    # there's no Pro to buy there, whatever the user's plan.
    def can_upgrade_to_pro?
      Stablemate.billing_enabled? && free?
    end

    # The number of monitors this user may own, or nil when there is no cap
    # (unlimited — self-host with the env cap OFF).
    def monitor_limit
      if Stablemate.billing_enabled?
        pro? ? Stablemate::PRO_PLAN_MONITOR_LIMIT : Stablemate::FREE_PLAN_MONITOR_LIMIT
      elsif Stablemate.monitor_cap_enabled?
        Stablemate::MAX_MONITORS_PER_USER
      end
    end

    # When there's no cap, a user is never at the cap. Suspended monitors are
    # excluded from the count.
    def at_monitor_cap?
      limit = monitor_limit
      return false if limit.nil?

      active_monitor_count >= limit
    end

    # Float::INFINITY when uncapped keeps callers (e.g. the gem sync) decrementing
    # without ever running out. Never negative.
    def remaining_monitor_slots
      limit = monitor_limit
      return Float::INFINITY if limit.nil?

      [ limit - active_monitor_count, 0 ].max
    end

    # How many cap slots this user is over the Free cap by (>= 0). Drives the
    # gated "choose your 5" downgrade (PRD §5.6): how many must be suspended.
    def over_free_cap_by
      [ active_monitor_count - Stablemate::FREE_PLAN_MONITOR_LIMIT, 0 ].max
    end

    private
      # Monitors that occupy a cap slot — everything except `suspended`.
      def active_monitor_count
        monitors.counting_toward_cap.count
      end
  end
end
