module Monitoring
  class Monitor
    # Operation object: aggregate one calendar day's uptime for a monitor.
    # Reached via `monitor.roll_up_uptime(day)` (RollupUptimeJob iterates + calls
    # this; the Uptime concern reads the results).
    #
    # For the given UTC day it computes:
    #   - measured window: the part of the day the monitor actually existed
    #     (created_at .. end-of-day). A day before the monitor was created, or a
    #     fully-paused day with no activity, has zero measured seconds → no-data
    #     (NOT down);
    #   - down_seconds: the measured seconds overlapped by any incident interval
    #     (open incidents are clamped to the end of the day);
    #   - up_seconds: measured seconds minus down seconds;
    #   - ping_count: PingEvents received that day.
    #
    # Idempotent: upserts by (monitor_id, day) so re-running a day overwrites the
    # row rather than inserting a duplicate. Returns the UptimeDayStat.
    #
    # NOTE on paused/pending days: Phase 2 has no status-history table, so we
    # can't know a past day's exact paused/pre-ping windows. We therefore derive
    # "no-data" from *evidence*: a day with zero pings and zero incident overlap,
    # on a monitor currently paused OR pending (created, never pinged), is treated
    # as no-data. This makes re-rolling/backfilling safe — a past day that
    # actually saw pings or an incident is never erased by a later pause (the live
    # current day still reflects live state via the Uptime concern). See spec
    # §3.1 ("paused/pending windows count as no-data, not down").
    class UptimeRollup
      def initialize(monitor)
        @monitor = monitor
      end

      def call(day)
        day = day.to_date
        day_start = day.to_time(:utc)
        day_end   = day_start + 1.day

        pings = ping_count(day_start, day_end)
        down  = raw_down_seconds(day_start, day_end)
        measured = measured_seconds(day_start, day_end, pings, down)
        up    = [ measured - down, 0 ].max
        # No measurable evidence (paused, no pings, no incident) → fully no-data.
        down  = 0 if measured.zero?

        upsert(day, up_seconds: up, down_seconds: down, ping_count: pings)
      end

      private
        # The seconds of this day the monitor was being measured. Days before
        # creation are no-data; the creation day is measured only from created_at
        # onward. A currently paused, suspended, OR pending monitor's day counts as
        # no-data ONLY when it has no evidence of activity (no pings, no incident
        # overlap) — so a real, already-recorded active day is never wiped by a
        # later pause/suspend, and a never-pinged (pending) monitor never shows
        # false 100% up. `suspended` (plan-downgrade, issue #19) is a not-monitored
        # state just like `paused`: without a status-history table we can't know
        # the past suspended windows, so an evidence-free suspended day is no-data,
        # not a phantom 100%-up day.
        def measured_seconds(day_start, day_end, pings, down)
          window_start = [ @monitor.created_at, day_start ].max
          return 0 if window_start >= day_end
          return 0 if !@monitor.monitored? && pings.zero? && down.zero?

          (day_end - window_start).to_i
        end

        # Down seconds = the in-window seconds overlapped by incident intervals.
        # An incident is "down" from started_at until resolved_at (or end of day
        # if still open / resolved later). Incidents don't overlap each other (the
        # open-incident invariant), so a plain sum of clamped overlaps is correct.
        # Clamped to the monitor's existence window so pre-creation time never
        # counts as down.
        def raw_down_seconds(day_start, day_end)
          window_start = [ @monitor.created_at, day_start ].max
          return 0 if window_start >= day_end

          @monitor.incidents.where("started_at < ?", day_end).find_each.sum do |incident|
            # An OPEN incident on a not-measured monitor (paused/suspended/pending)
            # is a stranded artifact — it must not extend downtime to end-of-day for
            # a window we weren't watching. Post-WU-2 pause/suspend resolve incidents,
            # so this only catches legacy data.
            next 0 if incident.resolved_at.nil? && !@monitor.monitored?

            interval_end = incident.resolved_at || day_end
            overlap_start = [ incident.started_at, window_start ].max
            overlap_end   = [ interval_end, day_end ].min
            [ (overlap_end - overlap_start).to_i, 0 ].max
          end
        end

        def ping_count(day_start, day_end)
          @monitor.ping_events.where(received_at: day_start...day_end).count
        end

        # Atomic, idempotent upsert keyed on the unique (monitor_id, day) index, so
        # two overlapping rollups (e.g. a backfill run racing the nightly job) for
        # the same day overwrite rather than collide on RecordNotUnique. upsert_all
        # bypasses validations — fine for these plain integer columns — and sets
        # timestamps itself, so we reload the row to return the persisted record.
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
