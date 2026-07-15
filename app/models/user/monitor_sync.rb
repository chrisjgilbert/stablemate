class User
  # Operation (architecture.md §3): idempotent bulk upsert of monitors from the
  # gem's sync payload. Owned by the user because the user owns the monitors.
  #
  # Reached via user.sync_monitors(app:, entries:) -> { registered:, skipped: }.
  #
  # Rules (phase-3 §3.3):
  # - Upsert by (user, registration_key).
  # - Existing monitor -> update name/interval/grace. ALWAYS allowed, even at cap.
  # - New monitor -> create with source: "gem", status: "pending", fresh ping_token.
  # - Cap is a graceful PARTIAL: register new monitors up to the remaining slots;
  #   the rest are returned under `skipped` with reason "limit_reached". Never
  #   raises / fails the whole request.
  # - No auto-delete: monitors absent from the payload are untouched.
  module MonitorSync
    extend ActiveSupport::Concern

    def sync_monitors(app: nil, entries: [])
      Operation.new(self).sync_monitors(entries:)
    end

    # The operation proper. Nested so user.sync_monitors stays the public seam.
    class Operation
      # One sanitized registration tuple from the payload. Guards against mass
      # assignment: only these four attributes are ever read from the entry —
      # user_id / status / source / ping_token are controlled by this operation,
      # never by the caller.
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

      def initialize(user)
        @user = user
      end

      def sync_monitors(entries:)
        registered = []
        skipped = []

        # Hold the user row lock across the whole run so the slot accounting is
        # atomic: without it two concurrent syncs each read the same remaining-slot
        # budget and both create, exceeding the cap (WU-3). Seed @slots AFTER the
        # lock so it reflects committed state; decrement locally per create. Every
        # expected per-entry failure (invalid shape, over cap, duplicate key) is
        # handled without raising, so the run also commits atomically — an
        # unexpected mid-loop error rolls the whole batch back rather than leaving
        # it half-applied.
        @user.with_lock do
          @slots = @user.remaining_monitor_slots

          Array(entries).each do |raw|
            entry = Entry.from(raw)
            next if entry.registration_key.blank?

            monitor = @user.monitors.find_by(registration_key: entry.registration_key)

            if monitor
              # Updating an existing monitor is always allowed (even at the cap).
              persist_update(monitor, entry, registered, skipped)
            elsif !valid_shape?(entry)
              # A malformed new entry must never consume a cap slot — and must report
              # "invalid", not "limit_reached", even when the user is over the cap
              # (validate the shape BEFORE the cap check). (§3.3)
              skipped << skip(entry, "invalid")
            elsif room_for_more?
              persist_create(entry, registered, skipped)
            else
              skipped << skip(entry, "limit_reached")
            end
          end
        end

        { registered:, skipped: }
      end

      private
        # Slots remaining for NEW monitors this run. Seeded once from the live
        # count and decremented by persist_create on each successful creation;
        # updates to existing monitors never consume a slot.
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

        # The contract (phase-3 §3.3) is graceful & partial: one malformed entry
        # must never raise or 500 the whole request, and must never leave the
        # payload half-applied. Each entry persists independently; an invalid one
        # is recorded under `skipped`, leaving the valid ones intact.
        def persist_update(monitor, entry, registered, skipped)
          attrs = { name: entry.name, expected_interval_seconds: entry.expected_interval_seconds,
                    grace_period_seconds: entry.grace_period_seconds }.compact
          if monitor.update(attrs)
            registered << monitor
          else
            skipped << skip(entry, "invalid")
          end
        end

        def persist_create(entry, registered, skipped)
          monitor = @user.monitors.new(
            registration_key: entry.registration_key,
            name: entry.name.presence || entry.registration_key,
            expected_interval_seconds: entry.expected_interval_seconds,
            grace_period_seconds: entry.grace_period_seconds,
            source: "gem",
            status: "pending"
          )

          if save_isolated(monitor)
            @slots -= 1
            registered << monitor
          else
            skipped << skip(entry, "invalid")
          end
        rescue ActiveRecord::RecordNotUnique
          # Concurrent boot (real bug): multiple Puma workers / containers run the
          # railtie's after_initialize sync at once with the SAME new keys. The
          # partial unique index on (user, registration_key) lets the first create
          # win; the losers raise RecordNotUnique. Treat that as the idempotent
          # upsert it is — re-find the now-existing row and update it, so it lands
          # in `registered` and the request never 500s. (Now that `sync_monitors` holds the
          # user row lock, same-user syncs serialise and this is nearly unreachable,
          # but it stays as a backstop.)
          existing = @user.monitors.find_by(registration_key: entry.registration_key)
          if existing
            persist_update(existing, entry, registered, skipped)
          else
            skipped << skip(entry, "invalid")
          end
        end

        # Persist the new monitor in its OWN savepoint (requires_new) so a
        # RecordNotUnique rolls back only this insert — never the enclosing
        # with_lock transaction (which would otherwise be poisoned on Postgres and
        # take every sibling create down with it). Returns save's boolean; a
        # RecordNotUnique propagates to the rescue above. With no enclosing
        # transaction (persist_create called directly) requires_new is just a plain
        # transaction, so the rescue path is unchanged.
        def save_isolated(monitor)
          @user.transaction(requires_new: true) { monitor.save }
        end

        def skip(entry, reason)
          { registration_key: entry.registration_key, reason: }
        end
    end
  end
end
