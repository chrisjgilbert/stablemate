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
                     # The rank exists to order the ticks, but SQL guarantees no
                     # row order for the outer SELECT — the subquery's ordering is
                     # an artifact of today's plan, not a contract. Order by it
                     # explicitly so each monitor's ticks stay newest→oldest (what
                     # mini_ticks reverses into the sparkline) under any plan.
                     .order(:monitor_id, :rn)

          ranked.each_with_object({}) do |row, acc|
            (acc[row.monitor_id] ||= []) << row.kind
          end
        end

        # The oldest day a rollup can still be written for: uptime_days_to_roll
        # clamps a never-rolled monitor's backfill here, so no day before this one
        # will ever gain an UptimeDayStat. PingEvent.prune! reads the same rule —
        # without it the two deadlock (M11): the rollup can't reach those days and
        # prune's "only delete rolled-up days" check won't release them, so their
        # raw pings sit there being warn-logged for ever.
        def uptime_backfill_horizon = Stablemate::PING_RETENTION.ago.to_date
      end

      # The complete days that still need a rollup for this monitor: from the day
      # after its last rolled day (or its creation day / the retention horizon,
      # whichever is later) through yesterday. Backfills missed runs. The job
      # iterates this and delegates to roll_up_uptime — the day-range rule lives
      # here on the record, not in the job.
      def uptime_days_to_roll(through: Date.current - 1)
        earliest    = [ created_at.to_date, self.class.uptime_backfill_horizon ].max
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
      # nothing was measured — today included. Derived from the same rows
      # uptime_series loads, so the detail panel renders both off ONE query.
      #
      # Today is blended in live from the same measurement the bar's today segment
      # is drawn from: it has no UptimeDayStat until the 00:10 rollup, so summing
      # persisted rows alone left an amber today bar sitting next to a stale
      # "100.00%" for up to 24h (#51 / F8) — and the API served that number.
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
      # incident open/resolve events, newest first (kind-ranked at equal
      # timestamps, so active incidents lead). Returns lightweight Event
      # structs (kind, at, label, duration_ms).
      def recent_events(limit: 12)
        events = []

        ping_events.order(received_at: :desc).limit(limit)
                   .pluck(:received_at, :duration_ms, :kind, :error).each do |received_at, duration_ms, kind, error|
          if kind == "failure"
            # The label stays one line in the feed (the partial truncates);
            # the full error lives on the incident banner.
            events << Event.new(:failure, received_at, "Error reported — #{error}", duration_ms)
          else
            events << Event.new(:ping, received_at, "Ping received", duration_ms)
          end
        end

        incidents.order(started_at: :desc).limit(limit).each do |incident|
          events << Event.new(:down, incident.started_at, incident_opened_label(incident))
          events << Event.new(:recovered, incident.resolved_at, "Recovered") if incident.resolved_at
        end

        # Newest first; ties broken by kind. Equal timestamps are real, not an
        # edge case: a reported failure's ping OPENS its incident at the same
        # instant, and a recovery resolves at its ping's instant — Ruby's
        # sort_by is unstable, so without the tiebreak the feed's row order
        # (and which row survives the limit) would differ between renders. The
        # incident narrative (down/recovered) sorts above the raw ping rows.
        events.sort_by { |e| [ -e.at.to_f, EVENT_TIE_ORDER.fetch(e.kind) ] }.first(limit)
      end

      # A single row in the recent-events feed.
      Event = Struct.new(:kind, :at, :label, :duration_ms)
      EVENT_TIE_ORDER = { down: 0, recovered: 1, failure: 2, ping: 3 }.freeze

      private
        # Cause-aware "went down" copy (job-failure-details.md §9): what took the
        # monitor down, not just that it went down.
        def incident_opened_label(incident)
          if incident.reported_error?
            "Went down — job reported an error"
          else
            "Went down — no ping received"
          end
        end

        # The rolled-up day stats for the window, loaded once and memoized so the
        # detail panel's uptime_series + uptime_percent share a single query.
        # Deliberately stops BEFORE today: today is always computed live
        # (live_today_stat), so a stray persisted row for today — a legacy or
        # hand-rolled one — can neither be double-counted in the percent nor
        # override the live bar segment.
        def windowed_day_stats(days)
          (@windowed_day_stats ||= {})[days] ||=
            uptime_day_stats.where(day: (Date.current - (days - 1))...Date.current).to_a
        end

        # Today's measurement so far, as an UNSAVED UptimeDayStat — the current day
        # has no persisted row until tonight's rollup. Derived from the monitor's
        # present state: paused/suspended/pending → 0/0 (no-data, never a phantom
        # green `up`; `suspended`, the plan-downgrade state from issue #19, is
        # not-monitored just like `paused`); otherwise today's down seconds so far
        # (from ANY incident overlapping today, open OR already resolved — a
        # same-day down-then-recovery must still count) against the elapsed
        # monitored time.
        #
        # ONE method feeds both readers — the bar's today segment
        # (live_today_status) and uptime_percent — so the % and the bar cannot
        # disagree, and today is classified by the same up/down/partial cutoffs it
        # will get once the rollup persists it (UptimeDayStat#status).
        #
        # Memoized because the detail page's uptime panel renders BOTH readers off
        # one monitor — the bar and the percent — so every one of those responses
        # ran today's incident scan twice for the same answer. (The API detail
        # endpoint serves only the percent, so it was already paying once.) Two
        # readers, one number, one scan. Keyed on the second it was taken in rather
        # than memoized outright: this is a snapshot of *now*, and a `travel_to` in
        # a test (or a day rolling over under a long-lived object) must get a fresh
        # one instead of yesterday's. Within a render the clock does not move, so
        # the key is stable exactly where the saving is.
        def live_today_stat
          now = Time.current
          return @live_today_stat if @live_today_stat_second == now.to_i

          @live_today_stat_second = now.to_i
          @live_today_stat = compute_live_today_stat(now)
        end

        def compute_live_today_stat(now)
          return UptimeDayStat.new(up_seconds: 0, down_seconds: 0) if paused? || suspended? || pending?

          window_start = [ created_at, first_ping_at, Date.current.to_time(:utc) ].compact.max
          return UptimeDayStat.new(up_seconds: 0, down_seconds: 0) if window_start >= now

          down = today_down_seconds(window_start, now)
          up   = [ (now - window_start).to_i - down, 0 ].max
          UptimeDayStat.new(up_seconds: up, down_seconds: down)
        end

        def live_today_status = live_today_stat.status

        # Down seconds from window_start through now, overlapped by any incident
        # interval (mirrors UptimeRollup#raw_down_seconds, but the window end is
        # "now" rather than end-of-day since today isn't rolled up yet). An
        # already-resolved incident counts the same as a still-open one. Scoped to
        # incidents that could actually overlap the window, so a long-lived
        # monitor's full incident history isn't scanned on every render.
        def today_down_seconds(window_start, now)
          incidents
            .where("started_at < ? AND (resolved_at IS NULL OR resolved_at >= ?)", now, window_start)
            .find_each.sum do |incident|
              overlap_start = [ incident.started_at, window_start ].max
              overlap_end   = [ incident.resolved_at || now, now ].min
              [ (overlap_end - overlap_start).to_i, 0 ].max
            end
        end
    end
  end
end
