class User
  # The gated "choose your 5" downgrade (PRD §5.6) as an operation owned by the
  # user, reached via user.downgrade_to_free!(keep_ids:). Closes the "go Pro → add
  # 100 → cancel → keep 100" loophole: a user over the Free cap must pick exactly
  # FREE_PLAN_MONITOR_LIMIT monitors to keep active; the rest are plan-suspended
  # (retained, uncounted) — never deleted. Only after the choice do we cancel the
  # Stripe subscription, after which the verified webhook flips plan → free.
  #
  # An over-cap account also reaches #enforce_free_cap! involuntarily, but NOT
  # immediately: an involuntary drop to Free opens a grace window and suspends
  # nothing (User::Subscription#sync_plan_from_subscription!, §12-J). Only if that
  # window expires unanswered does the daily backstop
  # (User#enforce_downgrade_fallback!) call #enforce_free_cap! to keep the oldest N.
  class Downgrade
    def initialize(user)
      @user = user
    end

    Result = Struct.new(:ok?, :error)

    # Voluntary downgrade. keep_ids = the monitors to leave active. Requires
    # exactly the Free cap's worth when over it (fewer/more is rejected); when at
    # or under the cap, no selection is needed.
    #
    # Order matters: we cancel Stripe FIRST, then suspend. If the Stripe call
    # raises (network/API), it propagates with no monitor touched — so we never
    # leave a user suspended-but-still-billing. The plan column itself is changed
    # only by the resulting webhook. The controller rescues Stripe errors.
    def to_free!(keep_ids: [])
      keep_ids = Array(keep_ids).map(&:to_i)
      keep = nil

      if @user.over_free_cap_by.positive?
        return Result.new(false, :must_choose) unless keep_ids.size == limit

        valid = active_scope.where(id: keep_ids)
        return Result.new(false, :must_choose) unless valid.count == limit

        keep = valid.ids
      end

      cancel_subscription!
      suspend_all_except(keep) if keep
      Result.new(true, nil)
    end

    # Resolve the involuntary choose-N lock (WU-6). The account already dropped to
    # Free but — during the grace window (§12-J) — nothing was suspended yet; the
    # user now picks exactly the Free cap's worth to keep active from among ALL their
    # monitors. The chosen stay (or return) active, the rest are suspended, and the
    # lock is cleared. Atomic so the account never sits half-repicked. (Any monitors
    # already suspended from a prior downgrade are still reactivated if chosen.)
    #
    # Stripe is cancelled first, exactly as in #to_free!. The involuntary drop is
    # usually a subscription that is already gone — in which case this is a no-op —
    # but NOT always: a card failure leaves it `past_due`, which drops the plan to
    # Free and opens this lock while Stripe keeps dunning. The picker tells that
    # user their subscription will be cancelled, and this is their only in-app route
    # (the billing page hides the Portal and Downgrade links once plan == free), so
    # committing the choice must actually cancel it. Otherwise a dunning retry
    # succeeds days later and they are billed for Pro with monitors suspended.
    # Cancel-then-suspend ordering means a Stripe failure propagates with no monitor
    # touched, and the call stays OUTSIDE the row lock below — never hold a lock
    # across a network round trip.
    def resolve_choice!(keep_ids: [])
      keep_ids = Array(keep_ids).map(&:to_i)
      keep = @user.monitors.where(id: keep_ids)
      return Result.new(false, :must_choose) unless keep.count == limit

      keep = keep.ids
      cancel_subscription!

      # with_lock, so the USER row is locked before any monitor row. Every other
      # path that touches both takes them in that order (the gem sync's cap
      # serialisation, the webhook's restore) — locking monitors first here would
      # invert the order and deadlock a concurrent sync or re-upgrade.
      @user.with_lock do
        @user.monitors.where(id: keep).where(status: "suspended").find_each(&:reactivate!)
        active_scope.where.not(id: keep).find_each(&:suspend!)
        @user.clear_downgrade_choice!
      end
      Result.new(true, nil)
    end

    # Involuntary path: ensure no more than the Free cap of monitors stay active.
    # Suspends the newest over-cap monitors (keeps the oldest, deterministic) so a
    # webhook-driven cancellation can't leave free users monitoring 100 things.
    # Idempotent; safe to call from a webhook.
    def enforce_free_cap!
      over = @user.over_free_cap_by
      return if over.zero?

      keep = active_scope.order(:created_at).limit(limit).ids
      suspend_all_except(keep)
    end

    private
      def limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
      def active_scope = @user.monitors.counting_toward_cap

      def suspend_all_except(keep_ids)
        active_scope.where.not(id: keep_ids).find_each(&:suspend!)
      end

      # Cancel the active Pro subscription at Stripe. All Pay coupling lives on the
      # Subscription concern; the plan flip is left to the resulting webhook (the
      # only writer of plan) so client and server can't drift.
      def cancel_subscription!
        @user.cancel_pro_subscription!
      end
  end
end
