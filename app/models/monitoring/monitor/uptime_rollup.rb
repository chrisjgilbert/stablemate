module Monitoring
  class Monitor
    # Aggregate one calendar day's uptime for a monitor, reached via
    # `monitor.roll_up_uptime(day)`.
    #
    # NOTE on paused/pending days: there is no status-history table, so we can't
    # know a past day's exact paused/pre-ping windows. We therefore derive
    # "no-data" from *evidence*: a day with zero pings and zero incident overlap,
    # on a monitor currently paused OR pending, is treated as no-data. This makes
    # re-rolling/backfilling safe — a past day that actually saw pings or an
    # incident is never erased by a later pause.
    class UptimeRollup
      def initialize(monitor)
        @monitor = monitor
      end

      def roll_up_uptime(day)
        day = day.to_date
        # Rolling today would clamp an open incident to end-of-day, scoring hours
        # that haven't elapsed yet as down — and uptime_days_to_roll resumes after
        # the last rolled day, so the bad row would never be re-rolled and would
        # block the real day from ever being rolled. Raising rather than no-op'ing
        # because no caller has a reason to ask.
        raise ArgumentError, "cannot roll up #{day}: only completed days can be rolled up" if day >= Date.current

        day_start = day.to_time(:utc)
        day_end   = day_start + 1.day

        pings = ping_count(day_start, day_end)
        down  = raw_down_seconds(day_start, day_end)
        measured = measured_seconds(day_start, day_end, pings, down)
        up    = [ measured - down, 0 ].max
        down  = 0 if measured.zero?

        upsert(day, up_seconds: up, down_seconds: down, ping_count: pings)
      end

      private
        # A not-monitored monitor's day counts as no-data ONLY when it has no
        # evidence of activity, so a real, already-recorded active day is never
        # wiped by a later pause/suspend, and a never-pinged monitor never shows
        # false 100% up.
        def measured_seconds(day_start, day_end, pings, down)
          window_start = measurement_window_start(day_start)
          return 0 if window_start.nil? || window_start >= day_end
          return 0 if !@monitor.monitored? && pings.zero? && down.zero?

          (day_end - window_start).to_i
        end

        # nil when the monitor has never pinged → no measured time at all, so a late
        # backfill can't record a never-pinged day as 100% up.
        def measurement_window_start(day_start)
          return nil if @monitor.first_ping_at.nil?

          [ @monitor.created_at, @monitor.first_ping_at, day_start ].max
        end

        # The shared rule on the record, which the live intraday reading uses too so
        # the two can't drift. Clamped to the monitor's existence window so
        # pre-creation time never counts as down.
        def raw_down_seconds(day_start, day_end)
          window_start = measurement_window_start(day_start)
          return 0 if window_start.nil? || window_start >= day_end

          @monitor.down_seconds_during(window_start...day_end)
        end

        def ping_count(day_start, day_end)
          @monitor.ping_events.where(received_at: day_start...day_end).count
        end

        # Keyed on the unique (monitor_id, day) index so two overlapping rollups
        # (e.g. a backfill run racing the nightly job) overwrite rather than collide.
        # upsert_all bypasses validations and sets timestamps itself, so we reload
        # the row to return the persisted record.
        def upsert(day, up_seconds:, down_seconds:, ping_count:)
          now = Time.current
          @monitor.uptime_day_stats.upsert_all(
            [ { monitor_id: @monitor.id, day:, up_seconds:, down_seconds:, ping_count:, created_at: now, updated_at: now } ],
            unique_by: %i[monitor_id day]
          )
          @monitor.uptime_day_stats.find_by!(day:)
        end
    end
  end
end
