class Project
  # Operation (docs/specs/projects.md §4.3): idempotent bulk upsert of monitors
  # from the gem's sync payload. MOVED from User::MonitorSync onto the noun that
  # now owns the monitors and the registration_key namespace.
  #
  # Reached via project.sync_monitors(app:, entries:) -> { registered:, skipped:,
  # conflicts: }.
  #
  # Rules (§3.3 / §4.3):
  # - Upsert by (project, registration_key) — the collision fix: the same key in
  #   two projects of one user no longer collides.
  # - Existing monitor -> update name/interval/grace. ALWAYS allowed, even at cap.
  # - New monitor -> create with source: "gem", status: "pending", fresh ping_token.
  # - Cap is a graceful PARTIAL and stays PER-USER: register new monitors up to the
  #   user's remaining slots (across all their projects); the rest come back under
  #   `skipped` with reason "limit_reached". Never raises / fails the whole request.
  # - No auto-delete: monitors absent from the payload are untouched.
  # - `app` (the gem's free-text app string) is recorded as advisory
  #   `last_synced_app`; a sync UPDATE where the stored value diverges from the
  #   incoming one is the shared-key collision (§13-B3), reported under `conflicts`.
  class MonitorSync
    # One sanitized registration tuple from the payload. Guards against mass
    # assignment: only these four attributes are ever read from the entry —
    # project_id / status / source / ping_token / last_synced_app are controlled by
    # this operation, never by the caller.
    Entry = Struct.new(:registration_key, :name, :expected_interval_seconds, :grace_period_seconds) do
      def self.from(raw)
        raw = raw.to_h.with_indifferent_access
        new(
          raw[:registration_key].presence,
          raw[:name].presence,
          raw[:expected_interval_seconds],
          raw[:grace_period_seconds]
        )
      end
    end

    def initialize(project)
      @project = project
    end

    def sync_monitors(app: nil, entries: [])
      @app = app.presence
      @registered = []
      @skipped = []
      @conflicts = []

      # Hold the USER row lock (not the project's) across the whole run so slot
      # accounting is atomic: the cap is per-user across projects, so two syncs of
      # DIFFERENT projects of the same user must serialise on the shared user, or
      # each reads the same remaining-slot budget and both create, exceeding the cap
      # (WU-3). Seed @slots AFTER the lock so it reflects committed state; decrement
      # locally per create. Every expected per-entry failure (invalid shape, over
      # cap, duplicate key) is handled without raising, so the run also commits
      # atomically — an unexpected mid-loop error rolls the whole batch back rather
      # than leaving it half-applied.
      @project.user.with_lock do
        @slots = @project.user.remaining_monitor_slots

        Array(entries).each do |raw|
          entry = Entry.from(raw)
          next if entry.registration_key.blank?

          monitor = @project.monitors.find_by(registration_key: entry.registration_key)

          if monitor
            # Updating an existing monitor is always allowed (even at the cap).
            persist_update(monitor, entry)
          elsif !valid_shape?(entry)
            # A malformed new entry must never consume a cap slot — and must report
            # "invalid", not "limit_reached", even when the user is over the cap
            # (validate the shape BEFORE the cap check). (§3.3)
            @skipped << skip(entry, "invalid")
          elsif room_for_more?
            persist_create(entry)
          else
            @skipped << skip(entry, "limit_reached")
          end
        end
      end

      { registered: @registered, skipped: @skipped, conflicts: @conflicts }
    end

    private
      # Slots remaining for NEW monitors this run. Seeded once from the user's live
      # count and decremented by persist_create on each successful creation; updates
      # to existing monitors never consume a slot.
      def room_for_more?
        @slots.positive?
      end

      # Cheap pre-check of the attributes the Monitor model requires for a new
      # record (name is defaulted to the key, so only the numeric fields matter).
      # Mirrors the model validations so an invalid entry is classified BEFORE
      # the cap check and never reaches create!. The create path still rescues
      # any residual validation failure as a belt-and-braces "invalid".
      def valid_shape?(entry)
        entry.expected_interval_seconds.to_i.positive? &&
          entry.grace_period_seconds.to_i >= 0
      end

      # The contract (§3.3) is graceful & partial: one malformed entry must never
      # raise or 500 the whole request, and must never leave the payload
      # half-applied. Each entry persists independently; an invalid one is recorded
      # under `skipped`, leaving the valid ones intact.
      #
      # Divergence detection (§3.2 / §13-B3): before overwriting, note when a
      # monitor already carries a DIFFERENT last_synced_app than this run's app —
      # that's one registration_key being synced by two apps under one project key
      # (the silent-corruption case the feature exists to catch). We record the key
      # under `conflicts` and update last_synced_app to the latest value.
      def persist_update(monitor, entry)
        @conflicts << monitor.registration_key if diverging_app?(monitor)

        attrs = { name: entry.name, expected_interval_seconds: entry.expected_interval_seconds,
                  grace_period_seconds: entry.grace_period_seconds, last_synced_app: @app }.compact
        if monitor.update(attrs)
          @registered << monitor
        else
          @skipped << skip(entry, "invalid")
        end
      end

      # A shared-key collision: the monitor was last synced by a different app than
      # the one syncing now. Only meaningful when both apps are named (a nil/absent
      # app can't diverge — old gems don't send one).
      def diverging_app?(monitor)
        @app.present? && monitor.last_synced_app.present? && monitor.last_synced_app != @app
      end

      def persist_create(entry)
        monitor = @project.monitors.new(
          registration_key: entry.registration_key,
          name: entry.name.presence || entry.registration_key,
          expected_interval_seconds: entry.expected_interval_seconds,
          grace_period_seconds: entry.grace_period_seconds,
          source: "gem",
          status: "pending",
          last_synced_app: @app
        )

        if save_isolated(monitor)
          @slots -= 1
          @registered << monitor
        else
          @skipped << skip(entry, "invalid")
        end
      rescue ActiveRecord::RecordNotUnique
        # Concurrent boot (real bug): multiple Puma workers / containers run the
        # railtie's after_initialize sync at once with the SAME new keys. The
        # partial unique index on (project, registration_key) lets the first create
        # win; the losers raise RecordNotUnique. Treat that as the idempotent
        # upsert it is — re-find the now-existing row and update it, so it lands
        # in `registered` and the request never 500s. (Now that `call` holds the
        # user row lock, same-user syncs serialise and this is nearly unreachable,
        # but it stays as a backstop.) The rescue is index-name-agnostic, so it is
        # unchanged by the (user → project) index swap.
        existing = @project.monitors.find_by(registration_key: entry.registration_key)
        if existing
          persist_update(existing, entry)
        else
          @skipped << skip(entry, "invalid")
        end
      end

      # Persist the new monitor in its OWN savepoint (requires_new) so a
      # RecordNotUnique rolls back only this insert — never the enclosing
      # with_lock transaction (which would otherwise be poisoned on Postgres and
      # take every sibling create down with it). Returns save's boolean; a
      # RecordNotUnique propagates to the rescue above. The transaction opens on the
      # USER (the row the lock is held on) so the savepoint nests inside that lock.
      def save_isolated(monitor)
        @project.user.transaction(requires_new: true) { monitor.save }
      end

      def skip(entry, reason)
        { registration_key: entry.registration_key, reason: }
      end
  end
end
