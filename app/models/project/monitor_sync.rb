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
  # - Existing monitor -> update name/interval/grace. ALWAYS allowed, even at cap
  #   — but never over a value the USER has since changed in the UI, unless
  #   recurring.yml genuinely changed it too (see #gem_may_write?).
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

        unique_entries(entries).each do |entry|
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
      # The payload sanitized into Entries, at most ONE per registration_key.
      # registration_key is the upsert identity, so a payload that lists a key
      # twice describes one monitor — processing it twice made the second pass
      # find the row the first had just written and push the SAME monitor into
      # `registered` again, so the gem saw one job as two (M7). The last
      # occurrence wins, which is the value the row is left with either way.
      # Blank keys are dropped: there is nothing to upsert them by.
      def unique_entries(entries)
        Array(entries)
          .map { |raw| Entry.from(raw) }
          .reject { |entry| entry.registration_key.blank? }
          .index_by(&:registration_key)
          .values
      end

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
      #
      # Read as NUMBERS, not through to_i: to_i turns both nil and "soon" into a
      # perfectly valid grace of 0, so entries the model's numericality
      # validations reject passed the shape check and — at the cap — came back
      # as "limit_reached", telling the operator to buy slots for an entry that
      # could never have registered. (M8)
      def valid_shape?(entry)
        interval = numeric(entry.expected_interval_seconds)
        grace = numeric(entry.grace_period_seconds)

        return false if interval.nil? || grace.nil?

        interval.positive? && !grace.negative?
      end

      # The value as a number, or nil when it isn't one — the same set the
      # model's numericality validation accepts (nil and non-numeric strings are
      # not numbers; a numeric string is).
      def numeric(value)
        Float(value.to_s, exception: false)
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

        attrs = gem_settings(monitor, entry).merge({ last_synced_app: @app }.compact)
        if monitor.update(attrs)
          @registered << monitor
        else
          @skipped << skip(entry, "invalid")
        end
      end

      # The three settings the gem derives from recurring.yml, paired with the
      # column remembering what it last SENT for each.
      GEM_SETTINGS = { name: :last_synced_name,
                       expected_interval_seconds: :last_synced_expected_interval_seconds,
                       grace_period_seconds: :last_synced_grace_period_seconds }.freeze

      # The settings this sync may write, plus the record of what it sent.
      #
      # The gem re-syncs on EVERY production boot, so writing these three
      # unconditionally meant a user who tightened a monitor in the UI (locked
      # decision #5 and docs/integrating.md invite exactly that) had it silently
      # reverted at the next deploy (F2). An absent value is still left alone —
      # old gems don't send everything.
      def gem_settings(monitor, entry)
        GEM_SETTINGS.each_with_object({}) do |(setting, remembered), attrs|
          incoming = entry[setting]
          next if incoming.nil?

          attrs[setting] = incoming if gem_may_write?(monitor, setting, remembered, incoming)
          attrs[remembered] = incoming
        end
      end

      # May this sync write `setting`, or is the stored value the user's?
      #
      # We can tell the two apart by what the gem last sent: while the stored
      # value still equals that, nobody has overridden it and the gem owns it.
      #
      # PRECEDENCE when BOTH have moved — the user overrode the value AND
      # recurring.yml genuinely changed it — is the gem's. The interval and
      # grace describe how often the job ACTUALLY runs; once that changes, an
      # override derived from the old schedule is stale and would false-alarm,
      # which is the failure this product exists to prevent. So the override is
      # protected from being undone by a re-sync that says nothing new, not from
      # real news about the schedule. (The user can override again; a false
      # `down` at 3am they cannot undo.)
      #
      # Nil remembered = a monitor registered before we started remembering. We
      # can't tell an override from an untouched value, so we don't touch it —
      # the first sync after the deploy is precisely when the clobber used to
      # happen — and we start remembering.
      #
      # KNOWN LIMIT for that first sync (pinned by a test below). If the stored
      # value and the incoming one already differ when we start remembering, the
      # two branches above can never both be false again for THAT value: stored
      # stays != last_sent, and an unchanged payload keeps arriving == last_sent.
      # So a `recurring.yml` change that was already in flight when the migration
      # deployed is refused until the schedule changes AGAIN, which does then
      # land. It is a genuine coin flip — on that first sync a divergence is
      # equally consistent with "the user tightened this" and "the schedule
      # changed" — and we deliberately resolve it toward never overwriting a
      # setting the user may have chosen. Cost: a stale cadence on monitors that
      # existed before this shipped. Revisit if that trade ever bites; today
      # there are no such monitors in production.
      def gem_may_write?(monitor, setting, remembered, incoming)
        last_sent = monitor.public_send(remembered)
        return false if last_sent.nil?

        # Compare through the column's own type: the payload is JSON, so the
        # numbers arrive as strings, and "3600" != 3600 would read every boot as
        # a schedule change and hand the clobber straight back.
        monitor.public_send(setting) == last_sent ||
          monitor.class.type_for_attribute(setting).cast(incoming) != last_sent
      end

      # A shared-key collision: the monitor was last synced by a different app than
      # the one syncing now. Only meaningful when both apps are named (a nil/absent
      # app can't diverge — old gems don't send one).
      def diverging_app?(monitor)
        @app.present? && monitor.last_synced_app.present? && monitor.last_synced_app != @app
      end

      def persist_create(entry)
        # The gem sends no name for most tasks, so the monitor is named after its
        # registration key — and the REMEMBERED name has to be that same
        # defaulted value, or the next sync would read our own default as a user
        # rename and freeze the name forever.
        name = entry.name.presence || entry.registration_key

        monitor = @project.monitors.new(
          registration_key: entry.registration_key,
          name: name,
          expected_interval_seconds: entry.expected_interval_seconds,
          grace_period_seconds: entry.grace_period_seconds,
          source: "gem",
          status: "pending",
          last_synced_app: @app,
          last_synced_name: name,
          last_synced_expected_interval_seconds: entry.expected_interval_seconds,
          last_synced_grace_period_seconds: entry.grace_period_seconds
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
