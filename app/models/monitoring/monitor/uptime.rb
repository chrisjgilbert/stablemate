module Monitoring
  class Monitor
    # Concern: read-side uptime presentation built on the rolled-up UptimeDayStats
    # (UptimeRollup writes them). It never re-scans raw pings for history — that is
    # why pruning is safe. Only the live current (incomplete) day is computed on
    # the fly from today's incident/state.
    module Uptime
      extend ActiveSupport::Concern

      MINI_TICKS = 16

      class_methods do
        # Batch-load the last MINI_TICKS ping kinds for each of the given monitor
        # ids in a SINGLE query, so the dashboard renders O(1) queries instead of
        # one per row (README DoD: no N+1 on index pages). Returns a hash of
        # monitor_id => [kind, ...] newest→oldest, ready to pass to
        # monitor.mini_ticks(kinds:). Uses a window function to take the top
        # MINI_TICKS rows per monitor.
        def mini_ticks_for(monitor_ids)
          return {} if monitor_ids.blank?

          ranked = PingEvent
                     .select(:monitor_id, :kind)
                     .from(
                       PingEvent
                         .select(
                           :monitor_id, :kind,
                           "ROW_NUMBER() OVER (PARTITION BY monitor_id ORDER BY received_at DESC) AS rn"
                         )
                         .where(monitor_id: monitor_ids),
                       :ping_events
                     )
                     .where("rn <= ?", MINI_TICKS)

          ranked.each_with_object({}) do |row, acc|
            (acc[row.monitor_id] ||= []) << row.kind
          end
        end
      end

      # The complete days that still need a rollup for this monitor: from the day
      # after its last rolled day (or its creation day / the retention horizon,
      # whichever is later) through yesterday. Backfills missed runs. The job
      # iterates this and delegates to roll_up_uptime — the day-range rule lives
      # here on the record, not in the job.
      def uptime_days_to_roll(through: Date.current - 1)
        earliest    = [ created_at.to_date, Stablemate::PING_RETENTION.ago.to_date ].max
        last_rolled = uptime_day_stats.maximum(:day)
        start_day   = last_rolled ? last_rolled + 1 : earliest

        return [] if start_day > through

        (start_day..through).to_a
      end

      # A `days`-element array of per-day status (:up / :partial / :down /
      # :no_data), oldest → newest. Past days come from UptimeDayStat; the final
      # element (today) is computed live so the bar updates intraday.
      def uptime_series(days: 90)
        stats = windowed_day_stats(days).index_by(&:day)

        (0...days).map do |offset|
          day = Date.current - (days - 1 - offset)
          if day == Date.current
            live_today_status
          else
            stats[day]&.status || :no_data
          end
        end
      end

      # Overall uptime over the window: sum(up) / sum(up + down), with no-data days
      # excluded from the denominator (they contribute 0/0). Returns nil when
      # nothing was measured. Derived from the same rows uptime_series loads, so the
      # detail panel renders both off ONE query.
      def uptime_percent(days: 90)
        up = down = 0
        windowed_day_stats(days).each do |stat|
          up   += stat.up_seconds
          down += stat.down_seconds
        end

        measured = up + down
        return nil if measured.zero?

        (100.0 * up / measured)
      end

      # Dashboard sparkline data: the last MINI_TICKS ping events as "up"/"down"
      # ticks, oldest → newest. A non-success ping (a recorded failure) is a down
      # tick; in V1 all recorded pings are successes, so this is up-heavy by design.
      #
      # Pass `kinds:` (newest→oldest kind strings, e.g. from
      # Monitoring::Monitor.mini_ticks_for) to avoid the per-monitor query — the
      # dashboard preloads all rows in one query to stay N+1-free (README DoD).
      def mini_ticks(kinds: nil)
        kinds ||= ping_events.order(received_at: :desc).limit(MINI_TICKS).pluck(:kind)
        kinds.reverse.map { |kind| kind == "success" ? "up" : "down" }
      end

      # The detail "recent events" feed: the most-recent pings interleaved with
      # incident open/resolve events, newest first. Active incidents (the open
      # `down` event) naturally lead because they carry the latest timestamp.
      # Returns lightweight Event structs (kind, at, label, duration_ms).
      def recent_events(limit: 12)
        events = []

        ping_events.order(received_at: :desc).limit(limit).pluck(:received_at, :duration_ms).each do |received_at, duration_ms|
          events << Event.new(:ping, received_at, "Ping received", duration_ms)
        end

        incidents.order(started_at: :desc).limit(limit).each do |incident|
          events << Event.new(:down, incident.started_at, "Went down — no ping received")
          events << Event.new(:recovered, incident.resolved_at, "Recovered") if incident.resolved_at
        end

        events.sort_by { |e| -e.at.to_f }.first(limit)
      end

      # A single row in the recent-events feed.
      Event = Struct.new(:kind, :at, :label, :duration_ms)

      private
        # The rolled-up day stats for the window, loaded once and memoized so the
        # detail panel's uptime_series + uptime_percent share a single query.
        def windowed_day_stats(days)
          (@windowed_day_stats ||= {})[days] ||=
            uptime_day_stats.where(day: (Date.current - (days - 1))..Date.current).to_a
        end

        # The live status of the current, not-yet-rolled day, derived from the
        # monitor's present state: paused/suspended/pending → no-data; an open
        # incident today → down (or partial if the day also saw up time); otherwise
        # up. `suspended` (plan-downgrade, issue #19) is not-monitored like `paused`,
        # so today's segment is no-data, not a phantom green `up`.
        def live_today_status
          return :no_data if paused? || suspended? || pending?

          incident = open_incident
          if incident
            started_today = incident.started_at.to_date >= Date.current
            # Down all of today so far if the incident predates today; otherwise it
            # only covers part of today → partial.
            started_today ? :partial : :down
          else
            :up
          end
        end
    end
  end
end
