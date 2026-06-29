class User
  # Plan-derived monitor capacity. Keyed off `plan`; in V1 every plan is "free".
  # The cap is config-gated (issue #16): with no cap configured the limit is
  # unlimited (a self-hoster has no cap); the managed instance sets a finite cap
  # via env. Paused monitors still occupy a slot (locked decision #8), so the
  # count is unconditional. Backs Monitoring::Monitor#within_monitor_cap.
  module Plan
    extend ActiveSupport::Concern

    # The number of monitors this user may own, or nil when the cap is OFF
    # (unlimited). (One plan today; this is the seam for paid tiers later.)
    def monitor_limit
      Stablemate::MAX_MONITORS_PER_USER if Stablemate.monitor_cap_enabled?
    end

    # When the cap is OFF, a user is never at the cap.
    def at_monitor_cap?
      return false unless Stablemate.monitor_cap_enabled?

      monitors.count >= monitor_limit
    end

    # When the cap is OFF, slots are effectively infinite — Float::INFINITY keeps
    # callers (e.g. the gem sync) decrementing without ever running out.
    def remaining_monitor_slots
      return Float::INFINITY unless Stablemate.monitor_cap_enabled?

      [ monitor_limit - monitors.count, 0 ].max
    end
  end
end
