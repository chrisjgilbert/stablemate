module Monitoring
  class Monitor
    # Read-side uptime presentation built on the rolled-up UptimeDayStats. It never
    # re-scans raw pings for history — that is why pruning is safe. Only the live
    # current (incomplete) day is computed on the fly.
    module Uptime
      extend ActiveSupport::Concern

      MINI_TICKS = 16

      class_methods do
        # Batch-loads every monitor's ticks in a SINGLE query so the dashboard
        # renders O(1) queries instead of one per row. Returns monitor_id =>
        # [kind, ...] newest→oldest, ready to pass to monitor.mini_ticks(kinds:).
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
                     # SQL guarantees no row order for the outer SELECT — the
                     # subquery's ordering is an artifact of today's plan, not a
                     # contract. Order by the rank explicitly so each monitor's
                     # ticks stay newest→oldest under any plan.
                     .order(:monitor_id, :rn)

          ranked.each_with_object({}) do |row, acc|
            (acc[row.monitor_id] ||= []) << row.kind
          end
        end

        # The oldest day a rollup can still be written for. PingEvent.prune! reads
        # the same rule — without it the two deadlock: the rollup can't reach those
        # days and prune's "only delete rolled-up days" check won't release them.
        def uptime_backfill_horizon = Stablemate::PING_RETENTION.ago.to_date
      end

      # The complete days that still need a rollup for this monitor, backfilling
      # missed runs. The day-range rule lives here on the record, not in the job.
      def uptime_days_to_roll(through: Date.current - 1)
        earliest    = [ created_at.to_date, self.class.uptime_backfill_horizon ].max
        last_rolled = uptime_day_stats.maximum(:day)
        start_day   = last_rolled ? last_rolled + 1 : earliest

        return [] if start_day > through

        (start_day..through).to_a
      end

      # A `days`-element array of per-day status (:up / :partial / :down /
      # :no_data), oldest → newest. The final element (today) is computed live so
      # the bar updates intraday.
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

      # No-data days are excluded from the denominator. Returns nil when nothing was
      # measured — today included.
      #
      # Today is blended in live from the same measurement the bar's today segment
      # is drawn from: it has no UptimeDayStat until the 00:10 rollup, so summing
      # persisted rows alone left an amber today bar sitting next to a stale
      # "100.00%" for up to 24h — and the API served that number.
      def uptime_percent(days: 90)
        up = down = 0
        (windowed_day_stats(days) + [ live_today_stat ]).each do |stat|
          up   += stat.up_seconds
          down += stat.down_seconds
        end

        measured = up + down
        return nil if measured.zero?

        (100.0 * up / measured)
      end

      # Seconds of `window` (a half-open Time range) this monitor was down. The
      # one rule the live intraday reading and the nightly rollup both measure by,
      # so the bar and the percentage cannot disagree about the same window.
      def down_seconds_during(window)
        DowntimeWindow.new(self, window).down_seconds
      end

      # Dashboard sparkline data, oldest → newest. Pass `kinds:` (newest→oldest, e.g.
      # from Monitoring::Monitor.mini_ticks_for) to avoid the per-monitor query.
      def mini_ticks(kinds: nil)
        kinds ||= ping_events.order(received_at: :desc).limit(MINI_TICKS).pluck(:kind)
        kinds.reverse.map { |kind| kind == "success" ? "up" : "down" }
      end

      # The most-recent pings interleaved with incident open/resolve events.
      def recent_events(limit: 12)
        events = []

        ping_events.order(received_at: :desc).limit(limit)
                   .pluck(:received_at, :duration_ms, :kind, :error).each do |received_at, duration_ms, kind, error|
          if kind == "failure"
            events << Event.new(:failure, received_at, "Error reported — #{error}", duration_ms)
          else
            events << Event.new(:ping, received_at, "Ping received", duration_ms)
          end
        end

        incidents.order(started_at: :desc).limit(limit).each do |incident|
          events << Event.new(:down, incident.started_at, incident_opened_label(incident))
          events << Event.new(:recovered, incident.resolved_at, "Recovered") if incident.resolved_at
        end

        # Equal timestamps are real, not an edge case: a reported failure's ping
        # OPENS its incident at the same instant, and a recovery resolves at its
        # ping's instant — Ruby's sort_by is unstable, so without the tiebreak the
        # feed's row order (and which row survives the limit) would differ between
        # renders.
        events.sort_by { |e| [ -e.at.to_f, EVENT_TIE_ORDER.fetch(e.kind) ] }.first(limit)
      end

      Event = Struct.new(:kind, :at, :label, :duration_ms)
      EVENT_TIE_ORDER = { down: 0, recovered: 1, failure: 2, ping: 3 }.freeze

      private
        def incident_opened_label(incident)
          if incident.reported_error?
            "Went down — job reported an error"
          else
            "Went down — no ping received"
          end
        end

        # Memoized so the detail panel's uptime_series + uptime_percent share a
        # single query. Deliberately stops BEFORE today: today is always computed
        # live, so a stray persisted row for today can neither be double-counted in
        # the percent nor override the live bar segment.
        def windowed_day_stats(days)
          (@windowed_day_stats ||= {})[days] ||=
            uptime_day_stats.where(day: (Date.current - (days - 1))...Date.current).to_a
        end

        # Today's measurement so far, as an UNSAVED UptimeDayStat — the current day
        # has no persisted row until tonight's rollup. Not-monitored or pending →
        # 0/0, never a phantom green `up`. The rollup side of this is automatic
        # (it keys off monitored?); here the states are listed EXPLICITLY, so
        # every new one — `retired` most recently — has to be added by hand or a
        # pruned monitor's today scores 100% up. Down seconds come from ANY incident
        # overlapping today, open OR already resolved — a same-day down-then-recovery
        # must still count.
        #
        # ONE method feeds both readers — the bar's today segment and uptime_percent
        # — so the % and the bar cannot disagree.
        #
        # Deliberately NOT memoized: any memo here answers with the state at first
        # read, which is wrong for a snapshot of *now* the moment the row changes or
        # the day rolls over.
        def live_today_stat
          now = Time.current

          return UptimeDayStat.new(up_seconds: 0, down_seconds: 0) if
            paused? || suspended? || retired? || pending?

          window_start = [ created_at, first_ping_at, Date.current.to_time(:utc) ].compact.max
          return UptimeDayStat.new(up_seconds: 0, down_seconds: 0) if window_start >= now

          # The same rule the nightly rollup applies to a completed day, with "now"
          # as the window end since today isn't rolled up yet.
          down = down_seconds_during(window_start...now)
          up   = [ (now - window_start).to_i - down, 0 ].max
          UptimeDayStat.new(up_seconds: up, down_seconds: down)
        end

        def live_today_status = live_today_stat.status
    end
  end
end
