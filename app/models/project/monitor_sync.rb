class Project
  # Idempotent bulk upsert of monitors from the gem's sync payload, reached via
  # project.sync_monitors(app:, entries:, declared_keys:, prune:) ->
  # { registered:, skipped:, conflicts:, orphaned:, retired: }.
  #
  # Three rules that aren't visible in the code below:
  # - No auto-delete, ever. Monitors absent from the payload are untouched by
  #   default and RETIRED on a prune run — reversibly, with their history.
  # - The cap is a graceful PARTIAL and stays PER-USER: the overflow comes back
  #   under `skipped`, never raising or failing the whole request.
  # - `orphaned` and `retired` are disjoint: a monitor this run retired is not
  #   also reported as merely orphaned, so the CLI prints each list as-is.
  class MonitorSync
    # Guards against mass assignment: only these five attributes are ever read from
    # the entry — project_id / status / source / ping_token / last_synced_app are
    # controlled by this operation, never by the caller.
    Entry = Struct.new(:registration_key, :name, :expected_interval_seconds,
                       :grace_period_seconds, :schedule) do
      def self.from(raw)
        raw = raw.to_h.with_indifferent_access
        new(
          raw[:registration_key].presence,
          raw[:name].presence,
          raw[:expected_interval_seconds],
          raw[:grace_period_seconds],
          raw[:schedule].presence
        )
      end
    end

    def initialize(project)
      @project = project
    end

    # `declared_keys` is every task key this run's registrar could SEE before its
    # own skips — which is strictly more than the payload carries. Only the CLI
    # holds it, and it is what separates "the task was deleted" from "the task is
    # there but its class: line is broken": auto-retiring the second turns a YAML
    # typo into monitoring-off for a live job. No declared_keys, no retirement.
    def sync_monitors(app: nil, entries: [], declared_keys: nil, prune: false)
      @app = app.presence
      @declared_keys = Array(declared_keys)
      @prune = prune
      @registered = []
      @skipped = []
      @conflicts = []
      @orphaned = []
      @retired = []

      # Hold the USER row lock (not the project's) across the whole run so slot
      # accounting is atomic: the cap is per-user across projects, so two syncs of
      # DIFFERENT projects of the same user must serialise on the shared user, or
      # each reads the same remaining-slot budget and both create, exceeding the
      # cap. Seed @slots AFTER the lock so it reflects committed state.
      @project.user.with_lock do
        @slots = @project.user.remaining_monitor_slots
        payload = unique_entries(entries)

        payload.each do |entry|
          monitor = @project.monitors.find_by(registration_key: entry.registration_key)

          if monitor&.retired?
            # The task is back. Reviving re-enters the cap, so it needs its own
            # branch: within_monitor_cap validates on: :create only, and the
            # find-then-update path below is deliberately "always allowed at the
            # cap" — without this you could retire one, fill the freed slot, and
            # restore the first, ending up silently over cap.
            revive(monitor, entry)
          elsif monitor
            # Updating an existing monitor is always allowed (even at the cap).
            persist_update(monitor, entry)
          elsif !valid_shape?(entry)
            # A malformed new entry must never consume a cap slot — and must report
            # "invalid", not "limit_reached", even when the user is over the cap
            # (validate the shape BEFORE the cap check).
            @skipped << skip(entry, "invalid")
          elsif room_for_more?
            persist_create(entry)
          else
            @skipped << skip(entry, "limit_reached")
          end
        end

        converge(payload.map(&:registration_key))
      end

      { registered: @registered, skipped: @skipped, conflicts: @conflicts,
        orphaned: @orphaned, retired: @retired }
    end

    private
      # An orphan is a monitor this project holds that matches no task in this
      # run — renamed, or removed from recurring.yml. The server computes the set
      # because it is the only party that sees both sides, and it re-applies the
      # rule to every retirement, so even a forged `prune: true` with a minimal
      # payload cannot reach anything the rule excludes.
      def converge(payload_keys)
        candidates = orphan_candidates(payload_keys)
        retiring, reporting = candidates.partition { |monitor| prunable?(monitor) }

        retiring.each do |monitor|
          monitor.retire!
          @retired << monitor.registration_key
        end
        @orphaned = reporting.map(&:registration_key)
      end

      # Four boundaries, each load-bearing:
      #
      # - `source: "gem"` keeps the §8 `manual-<id>` backfill out permanently.
      #   Those rows are declared in no repo, so no run can ever re-declare them.
      # - Both sides of the app match must be PRESENT. A row with a NULL
      #   last_synced_app (old gems didn't always send `app`) belongs to no app, so
      #   no run may claim it; and a payload with no `app` reports nothing at all,
      #   since nil-matching-nil would hand every unattributed row to whichever app
      #   syncs first.
      # - A row with no registration_key cannot be named in a report, and an empty
      #   payload would otherwise sweep every one of them in (`NOT IN ()` is true).
      # - Already-retired monitors are converged: re-reporting them every run would
      #   print a retirement notice for something retired weeks ago.
      def orphan_candidates(payload_keys)
        return Monitoring::Monitor.none if @app.blank?

        @project.monitors
                .where(source: "gem", last_synced_app: @app)
                .where.not(registration_key: nil)
                .where.not(registration_key: payload_keys)
                .not_retired
      end

      # Retire only what the flag asks for AND the CLI could see was gone. A
      # candidate the registrar DID see is present-but-not-registerable: reported,
      # never retired.
      def prunable?(monitor)
        @prune && @declared_keys.present? && !@declared_keys.include?(monitor.registration_key)
      end

      def revive(monitor, entry)
        unless room_for_more?
          # Left retired, deliberately: an over-cap revive that half-applied would
          # be a monitor carrying this run's settings while still not monitored.
          @skipped << skip(entry, "limit_reached")
          return
        end

        # Settings first, then the revive. The re-armed window has to be measured
        # against the interval this run is registering, and persist_update's
        # recompute_next_due_at callback would otherwise re-derive next_due_at from
        # the last PRE-retirement ping and hand back the stale window revive exists
        # to avoid.
        return unless persist_update(monitor, entry)

        monitor.revive!
        @slots -= 1 unless monitor.suspended?
      end

      # At most ONE entry per registration_key: it is the upsert identity, so a
      # payload that lists a key twice describes one monitor, and processing it
      # twice pushed the SAME monitor into `registered` again. The last occurrence
      # wins, which is the value the row is left with either way.
      def unique_entries(entries)
        Array(entries)
          .map { |raw| Entry.from(raw) }
          .reject { |entry| entry.registration_key.blank? }
          .index_by(&:registration_key)
          .values
      end

      def room_for_more?
        @slots.positive?
      end

      # Mirrors the model validations so an invalid entry is classified BEFORE the
      # cap check and never reaches create!.
      #
      # Read as NUMBERS, not through to_i: to_i turns both nil and "soon" into a
      # perfectly valid grace of 0, so entries the model's numericality validations
      # reject passed the shape check and — at the cap — came back as
      # "limit_reached", telling the operator to buy slots for an entry that could
      # never have registered.
      def valid_shape?(entry)
        interval = numeric(entry.expected_interval_seconds)
        grace = numeric(entry.grace_period_seconds)

        return false if interval.nil? || grace.nil?

        interval.positive? && !grace.negative?
      end

      def numeric(value)
        Float(value.to_s, exception: false)
      end

      # Divergence detection (§13-B3): before overwriting, note when a monitor
      # already carries a DIFFERENT last_synced_app than this run's app — that's one
      # registration_key being synced by two apps under one project key, the silent
      # corruption case the feature exists to catch.
      #
      # `schedule` is written like any other setting the payload carries, and
      # absent still means untouched: a c.monitors entry declared with a bare
      # interval has no schedule and sends none. Nothing reads it — V1 detection
      # is interval-based — but storing it now makes cron-aware detection a
      # server-only upgrade later, with no gem release and no wire migration.
      #
      # Returns whether the monitor was written, so the revive path can stop when
      # this run's settings were rejected.
      def persist_update(monitor, entry)
        @conflicts << monitor.registration_key if diverging_app?(monitor)

        attrs = gem_settings(monitor, entry)
                  .merge({ last_synced_app: @app, schedule: entry.schedule }.compact)
        if monitor.update(attrs)
          @registered << monitor
          true
        else
          @skipped << skip(entry, "invalid")
          false
        end
      end

      # The three settings the gem derives from recurring.yml, paired with the
      # column remembering what it last SENT for each.
      GEM_SETTINGS = { name: :last_synced_name,
                       expected_interval_seconds: :last_synced_expected_interval_seconds,
                       grace_period_seconds: :last_synced_grace_period_seconds }.freeze

      # The gem re-syncs on EVERY production boot, so writing these three
      # unconditionally meant a user who tightened a monitor in the UI had it
      # silently reverted at the next deploy. An absent value is still left alone —
      # old gems don't send everything.
      def gem_settings(monitor, entry)
        GEM_SETTINGS.each_with_object({}) do |(setting, remembered), attrs|
          incoming = entry[setting]
          next if incoming.nil?

          attrs[setting] = incoming if gem_may_write?(monitor, setting, remembered, incoming)
          attrs[remembered] = incoming
        end
      end

      # May this sync write `setting`, or is the stored value the user's? We can
      # tell the two apart by what the gem last sent: while the stored value still
      # equals that, nobody has overridden it and the gem owns it.
      #
      # PRECEDENCE when BOTH have moved is the gem's. Once the schedule genuinely
      # changes, an override derived from the old one is stale and would
      # false-alarm, which is the failure this product exists to prevent.
      #
      # Nil remembered = a monitor registered before we started remembering. We
      # can't tell an override from an untouched value, so we don't touch it, and
      # we start remembering. KNOWN LIMIT (pinned by a test): if the stored and
      # incoming values already differ at that point, a `recurring.yml` change
      # already in flight is refused until the schedule changes AGAIN. Deliberately
      # resolved toward never overwriting a setting the user may have chosen.
      def gem_may_write?(monitor, setting, remembered, incoming)
        last_sent = monitor.public_send(remembered)
        return false if last_sent.nil?

        # Compare through the column's own type: the payload is JSON, so the
        # numbers arrive as strings, and "3600" != 3600 would read every boot as
        # a schedule change and hand the clobber straight back.
        monitor.public_send(setting) == last_sent ||
          monitor.class.type_for_attribute(setting).cast(incoming) != last_sent
      end

      # Only meaningful when both apps are named (a nil/absent app can't diverge —
      # old gems don't send one).
      def diverging_app?(monitor)
        @app.present? && monitor.last_synced_app.present? && monitor.last_synced_app != @app
      end

      def persist_create(entry)
        # The gem sends no name for most tasks, so the monitor is named after its
        # registration key — and the REMEMBERED name has to be that same defaulted
        # value, or the next sync would read our own default as a user rename and
        # freeze the name forever.
        name = entry.name.presence || entry.registration_key

        monitor = @project.monitors.new(
          registration_key: entry.registration_key,
          name: name,
          expected_interval_seconds: entry.expected_interval_seconds,
          grace_period_seconds: entry.grace_period_seconds,
          schedule: entry.schedule,
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
        # Concurrent boot: multiple Puma workers / containers run the railtie's
        # after_initialize sync at once with the SAME new keys. Treat the loser as
        # the idempotent upsert it is — re-find the now-existing row and update it,
        # so it lands in `registered` and the request never 500s.
        existing = @project.monitors.find_by(registration_key: entry.registration_key)
        if existing
          persist_update(existing, entry)
        else
          @skipped << skip(entry, "invalid")
        end
      end

      # Persist the new monitor in its OWN savepoint (requires_new) so a
      # RecordNotUnique rolls back only this insert — never the enclosing with_lock
      # transaction (which would otherwise be poisoned on Postgres and take every
      # sibling create down with it). The transaction opens on the USER so the
      # savepoint nests inside that lock.
      def save_isolated(monitor)
        @project.user.transaction(requires_new: true) { monitor.save }
      end

      def skip(entry, reason)
        { registration_key: entry.registration_key, reason: }
      end
  end
end
