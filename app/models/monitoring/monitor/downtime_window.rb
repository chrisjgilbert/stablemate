module Monitoring
  class Monitor
    # How many seconds of a half-open time window this monitor was down, summed
    # from the incidents overlapping it. Reached via
    # monitor.down_seconds_during(window).
    #
    # ONE rule, two readers — the live intraday reading (whose window ends at
    # "now") and the nightly rollup (whose window is a calendar day). They were
    # separate near-identical implementations, and the comment on one pointed at
    # the other as its mirror; that is how the uptime bar and the uptime
    # percentage come to disagree about the same day. Incidents don't overlap each
    # other (the open-incident invariant), so a plain sum of clamped overlaps is
    # correct.
    #
    # The window is a Range rather than two Times: they are the same type and
    # adjacent, so transposing them would silently return 0 in the one class whose
    # whole identity is the window.
    class DowntimeWindow
      def initialize(monitor, window)
        @monitor = monitor
        @window = window
      end

      def down_seconds
        overlapping_incidents.find_each.sum do |incident|
          # A stranded OPEN incident on a monitor nobody is watching must not
          # extend downtime to the end of a window we weren't measuring.
          # Pause/suspend resolve incidents, so this only catches legacy data.
          next 0 if incident.open? && !@monitor.monitored?

          overlap_seconds(incident)
        end
      end

      private
        def window_start = @window.begin
        def window_end   = @window.end

        # An incident resolved before the window began would clamp to a negative
        # overlap and contribute 0 anyway — excluding it in SQL keeps a long-lived
        # monitor's full incident history off the query.
        def overlapping_incidents
          @monitor.incidents.where(
            "started_at < ? AND (resolved_at IS NULL OR resolved_at >= ?)",
            window_end, window_start
          )
        end

        # An open incident is down through to the end of the window — "now" for the
        # live reading, end-of-day for the rollup.
        def overlap_seconds(incident)
          overlap_start = [ incident.started_at, window_start ].max
          overlap_end   = [ incident.resolved_at || window_end, window_end ].min

          [ (overlap_end - overlap_start).to_i, 0 ].max
        end
    end
  end
end
