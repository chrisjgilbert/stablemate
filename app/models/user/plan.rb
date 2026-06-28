class User
  # Plan-derived monitor capacity. Keyed off `plan`; in V1 every plan is "free"
  # and the cap is the single constant MAX_MONITORS_PER_USER. Paused monitors
  # still occupy a slot (locked decision #8), so the count is unconditional.
  # Backs Monitoring::Monitor#within_monitor_cap.
  module Plan
    extend ActiveSupport::Concern

    # The number of monitors this user may own. (One plan today; this is the seam
    # for paid tiers later.)
    def monitor_limit
      Stablemate::MAX_MONITORS_PER_USER
    end

    def at_monitor_cap?
      monitors.count >= monitor_limit
    end

    def remaining_monitor_slots
      [ monitor_limit - monitors.count, 0 ].max
    end
  end
end
