module Monitoring
  class Monitor
    # Prune (v1-scope §6.1) — reached via monitor.retire! / monitor.revive!.
    #
    # Retiring is what `PRUNE=1` does to a monitor whose task has left the config:
    # history kept, cap slot freed, not monitored, and revived automatically when
    # the task comes back. Never a delete — a wrong prune then costs one deploy of
    # not-monitoring and is fully reversed by the next sync that includes the task.
    class Retirement
      def initialize(monitor)
        @monitor = monitor
      end

      # Idempotent — an already-retired monitor keeps the status it was retired
      # FROM, so a second prune can't overwrite the memory with "retired" and lose
      # the user's pause.
      #
      # The open incident is resolved first and WITHOUT an alert, exactly as
      # pause! and suspend! do: a stranded open incident on a not-monitored
      # monitor is counted as downtime by the rollup forever, so the outage day
      # would score 100% up. with_lock (not a bare transaction) so the incident is
      # read under SELECT ... FOR UPDATE and a detection sweep cannot open one
      # between the read and the flip.
      def retire!
        @monitor.with_lock do
          next if @monitor.retired?

          retiring_from = @monitor.status
          @monitor.resolve_open_incident!
          @monitor.update!(status: "retired", status_before_retirement: retiring_from)
        end
      end

      # NOT reactivate_heartbeat!, and that is the whole design of this method.
      # The retirement window has no pings by construction — the task was declared
      # absent — so next_due_at is stale on virtually every revive, and
      # reactivate_heartbeat!'s overdue arm would call flag_missed!: a down email
      # fired during the deploy that RESTORES the task, before the restored job
      # could possibly have run. Pause-resume's overdue means missed runs of a
      # live job; retire's overdue is an artifact of the declared-absent window.
      #
      # So: a fresh window and no alert. If the restored job then fails to run,
      # detection fires after interval + grace with a true down alert.
      #
      # TWO DEVIATIONS from §6.1's "restore `paused`, otherwise set `up`"
      # (CLAUDE.md "say so"), because taken literally that rule reaches two states
      # it was not written for:
      #
      # - `suspended` is restored too. Reviving a plan-suspended monitor to `up`
      #   would silently un-suspend it — the cap evasion CheckIn's own guard
      #   exists to prevent. Retirement changed nothing about it being
      #   unmonitored, so revive puts it back as it was.
      # - A monitor that has NEVER checked in goes back to `pending`, which is
      #   what reactivate_heartbeat! does for that case and for the same reason.
      #   `up` on a never-pinged monitor is the phantom green §11 rejects the
      #   preview ping over: live_today_stat has no first_ping_at to measure from,
      #   so it would score today 100% up for a job that has never once reported —
      #   and detection would then email a missed check-in for it.
      def revive!(at: Time.current)
        return unless @monitor.retired?

        remembered = @monitor.status_before_retirement

        if Monitor::NOT_MONITORED_STATUSES.include?(remembered)
          # The fresh window is re-armed here too, not only on the `up` branch:
          # `paused` is resumed by the USER, and reactivate_heartbeat! reads
          # next_due_at when they do. Left at its pre-retirement value it is stale
          # by the whole declared-absent window, so the first click of Resume
          # flags missed and emails the outage this method exists to prevent.
          @monitor.update!(status: remembered, status_before_retirement: nil, next_due_at: due_at(at))
        elsif !@monitor.ever_pinged?
          @monitor.update!(status: "pending", status_before_retirement: nil)
        else
          @monitor.update!(status: "up", status_before_retirement: nil, next_due_at: due_at(at))
        end
      end

      private
        # A fresh window measured from now, never from the last (pre-retirement)
        # ping. A monitor with no interval has nothing to arm — it will fail
        # validation on save anyway, and inventing a due time would be worse.
        def due_at(at)
          return nil if @monitor.expected_interval_seconds.blank?

          at + @monitor.expected_interval_seconds.seconds
        end
    end
  end
end
