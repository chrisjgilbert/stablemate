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
    # the entry — project_id / status / source / last_synced_app are controlled by
    # this operation, never by the caller.
    Entry = Struct.new(:registration_key, :name, :expected_interval_seconds,
                       :grace_period_seconds, :schedule) do
      def self.from(raw)
        raw = raw.to_h.with_indifferent_access
        new(
          # Normalised to a STRING, because the key is the upsert identity and it
          # is matched two ways: in SQL, where Active Record casts it through the
          # column type, and in Ruby, against the preloaded `existing` hash, which
          # does not. A payload sending a numeric key (`recurring.yml` keys are
          # YAML keys — `123:` parses as an Integer) would miss the hash but match
          # the column, so the run would take the CREATE path for a row that
          # exists: at the cap that reports `limit_reached` for a monitor the rules
          # say updates are always allowed for, and for a retired one it skips the
          # revive branch entirely, leaving it unmonitored while reporting it back
          # as registered.
          raw[:registration_key].presence&.to_s,
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
      # A Set, because prunable? asks it once per orphan candidate and the whole
      # loop runs inside the user's row lock: an app declaring 300 tasks with 300
      # orphans is ~90,000 string compares held against every other sync for that
      # user. Set#present? reads the same as the Array's did.
      @declared_keys = Array(declared_keys).to_set
      @prune = prune
      @registered = []
      @skipped = []
      @conflicts = []
      @orphaned = []
      @retired = []
      # Monitors ENTERING the project's monitored set — created or revived. Not
      # @registered, which persist_update also fills: an idempotent re-sync
      # matches every existing row and would broadcast on every deploy of every
      # host, re-rendering a panel whose state did not move.
      @arrived = 0

      # Hold the USER row lock (not the project's) across the whole run so slot
      # accounting is atomic: the cap is per-user across projects, so two syncs of
      # DIFFERENT projects of the same user must serialise on the shared user, or
      # each reads the same remaining-slot budget and both create, exceeding the
      # cap. Seed @slots AFTER the lock so it reflects committed state.
      @project.user.with_lock do
        payload = unique_entries(entries)

        # Converge FIRST, then seed the budget. A rename is an add plus an orphan
        # in the SAME run, so a budget read before the retirement refuses the
        # renamed task with limit_reached and frees its slot moments later —
        # leaving the live renamed job monitored by nothing until the next deploy,
        # and telling the operator to buy a slot that existed. Retiring first
        # cannot reach anything this payload names: the orphan rule excludes every
        # key the payload carries.
        payload_keys = payload.map(&:registration_key)
        converge(payload_keys)
        @slots = @project.user.remaining_monitor_slots

        # One query for the whole payload, not one per entry. The gem re-syncs on
        # every production boot from every worker and container, so a 200-task app
        # was doing 200 round trips inside the user's FOR UPDATE lock, serialising
        # every other sync for that user behind them. Converge cannot have touched
        # any of these rows — the orphan rule excludes every key the payload names.
        existing = @project.monitors.where(registration_key: payload_keys).index_by(&:registration_key)

        payload.each do |entry|
          monitor = existing[entry.registration_key]

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
      end

      # Once per run, not once per monitor: a 200-task app would otherwise queue
      # 200 renders of one panel. And only when a monitor actually ARRIVED — the
      # ladder reads "any monitors?" and "any ever pinged?", so a re-sync that
      # merely updated existing rows cannot have moved it.
      @project.broadcast_setup_progress if @arrived.positive?

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
          if retire_isolated(monitor)
            @retired << monitor.registration_key
          else
            reporting << monitor
          end
        end
        @orphaned = reporting.map(&:registration_key)
      end

      # Retire in its OWN savepoint, and swallow the invalid row — the same shape
      # as save_isolated, for the same reason. Every other write in this operation
      # is deliberately non-raising: a bad entry comes back under `skipped` and
      # the rest of the payload still registers. `retire!` is the one bang, so a
      # row that no longer passes validation (a legacy monitor with a NULL
      # interval, say) would propagate RecordInvalid out of the enclosing
      # with_lock, 500 the request and roll back every OTHER task in the payload —
      # one stale row silently un-registering a whole deploy. It is reported as
      # the orphan it is instead.
      def retire_isolated(monitor)
        @project.user.transaction(requires_new: true) { monitor.retire! }
        true
      rescue ActiveRecord::RecordInvalid
        false
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

        @arrived += 1
        monitor.revive!
        # Retirement restores what it retired FROM, and for `suspended` that alone
        # strands the monitor: every un-suspender runs off a plan change and none of
        # them can see a retired row — User::Subscription#restore_suspended_monitors!
        # scopes on `status == "suspended"`, and Downgrade#resolve_choice! offers
        # only `not_retired` monitors as keepers — so an upgrade during the
        # retirement misses it forever. This run holds a free slot for it, so
        # finish the job here rather than report `registered` for a monitor nothing
        # watches. (Which is also what makes the cap gate above the honest one: a
        # revive always ends monitored, so it always costs a slot.)
        monitor.reactivate! if monitor.suspended?
        @slots -= 1
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

        # `schedule` is written THROUGH, nil included — the one field where absent
        # does not mean untouched. The gem omits it precisely when there is no
        # schedule (`Registrars::DeclaredMonitors` sends none for a `c.monitors`
        # entry, and `Hash#slice` drops the absent key), so compacting it away
        # would strand the old cron string on a task that moved from
        # `recurring.yml` into `c.monitors` — and the show page's config panel
        # renders that string as the authoritative source of the monitor's
        # config, so a stale one is a false statement, not a stale cache.
        #
        # `last_synced_app` still compacts: a nil app is an old gem that sent
        # none, and clearing it would blind the cross-app conflict guard.
        attrs = declared_settings(entry)
                  .merge({ last_synced_app: @app }.compact)
                  .merge(schedule: entry.schedule)
        if monitor.update(attrs)
          @registered << monitor
          true
        else
          @skipped << skip(entry, "invalid")
          false
        end
      end

      # The three settings the gem derives from recurring.yml. The repo is the
      # only writer of monitor config now (§3.1), so each is written whenever the
      # payload carries it — there is no second party to arbitrate against, and
      # no refusing branch that can strand a monitor on a value only the deleted
      # edit form could correct.
      #
      # ABSENT still means untouched, and that is not a leftover of the old
      # arbitration: old gems send partial payloads, so "write unconditionally"
      # read literally would write a missing name as nil and fail validation.
      DECLARED_SETTINGS = %i[name expected_interval_seconds grace_period_seconds].freeze

      def declared_settings(entry)
        DECLARED_SETTINGS.each_with_object({}) do |setting, attrs|
          incoming = entry[setting]
          attrs[setting] = incoming unless incoming.nil?
        end
      end

      # Only meaningful when both apps are named (a nil/absent app can't diverge —
      # old gems don't send one).
      def diverging_app?(monitor)
        @app.present? && monitor.last_synced_app.present? && monitor.last_synced_app != @app
      end

      def persist_create(entry)
        # The gem sends no name for most tasks, so the monitor is named after its
        # registration key.
        monitor = @project.monitors.new(
          registration_key: entry.registration_key,
          name: entry.name.presence || entry.registration_key,
          expected_interval_seconds: entry.expected_interval_seconds,
          grace_period_seconds: entry.grace_period_seconds,
          schedule: entry.schedule,
          source: "gem",
          status: "pending",
          last_synced_app: @app
        )

        if save_isolated(monitor)
          @slots -= 1
          @registered << monitor
          @arrived += 1
        else
          @skipped << skip(entry, "invalid")
        end
      rescue ActiveRecord::RecordNotUnique
        # Concurrent sync: `kamal app exec` fans out across hosts in parallel
        # (§6.2), so several containers post the SAME new keys at once. (It used
        # to be the railtie's after_initialize sync racing across Puma workers;
        # boot registers nothing now — §3.1 — but the race is live for the same
        # reason.) Treat the loser as the idempotent upsert it is — re-find the
        # now-existing row and update it, so it lands in `registered` and the
        # request never 500s.
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
