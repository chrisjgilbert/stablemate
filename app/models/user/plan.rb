class User
  # Plan-derived monitor capacity. `suspended` monitors never count toward the cap;
  # `paused` ones still do (locked decision #8).
  module Plan
    extend ActiveSupport::Concern

    FREE = "free".freeze
    PRO  = "pro".freeze

    def free? = plan == FREE
    def pro?  = plan == PRO

    # Used by every "Upgrade" CTA so they can't drift on the eligibility rule.
    # `free?` alone is not the rule, because a past_due account IS free while
    # Stripe is still dunning its live subscription: offering it a checkout put
    # every one of those CTAs one click away from Billing::CheckoutsController's
    # "You're already on Pro." This is that guard's exact complement.
    def can_upgrade_to_pro?
      Stablemate.billing_enabled? && free? && !billed_for_pro?
    end

    # nil when there is no cap (unlimited — self-host with the env cap OFF).
    def monitor_limit
      if Stablemate.billing_enabled?
        pro? ? Stablemate::PRO_PLAN_MONITOR_LIMIT : Stablemate::FREE_PLAN_MONITOR_LIMIT
      elsif Stablemate.monitor_cap_enabled?
        Stablemate::MAX_MONITORS_PER_USER
      end
    end

    def at_monitor_cap?
      limit = monitor_limit
      return false if limit.nil?

      active_monitor_count >= limit
    end

    # Float::INFINITY when uncapped keeps callers (e.g. the gem sync) decrementing
    # without ever running out.
    def remaining_monitor_slots
      limit = monitor_limit
      return Float::INFINITY if limit.nil?

      [ limit - active_monitor_count, 0 ].max
    end

    def over_free_cap_by
      [ active_monitor_count - Stablemate::FREE_PLAN_MONITOR_LIMIT, 0 ].max
    end

    private
      def active_monitor_count
        monitors.counting_toward_cap.count
      end
  end
end
