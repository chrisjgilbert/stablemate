class User
  # The gated "choose your 5" downgrade (PRD §5.6), reached via
  # user.downgrade_to_free!(keep_ids:). Closes the "go Pro → add 100 → cancel →
  # keep 100" loophole: the unchosen monitors are plan-suspended (retained,
  # uncounted) — never deleted.
  class Downgrade
    def initialize(user)
      @user = user
    end

    Result = Struct.new(:ok?, :error)

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

    # Resolve the involuntary choose-N lock: the account already dropped to Free
    # but, during the grace window, nothing was suspended yet.
    #
    # Stripe is cancelled first, exactly as in #to_free!. The involuntary drop is
    # usually a subscription that is already gone — in which case this is a no-op —
    # but NOT always: a card failure leaves it `past_due`, which drops the plan to
    # Free and opens this lock while Stripe keeps dunning. Committing the choice
    # must actually cancel it, or a dunning retry succeeds days later and they are
    # billed for Pro with monitors suspended. The call stays OUTSIDE the row lock
    # below — never hold a lock across a network round trip.
    def resolve_choice!(keep_ids: [])
      keep_ids = Array(keep_ids).map(&:to_i)
      keep = @user.monitors.where(id: keep_ids)
      return Result.new(false, :must_choose) unless keep.count == limit

      keep = keep.ids
      cancel_subscription!

      # with_lock, so the USER row is locked before any monitor row. Every other
      # path that touches both takes them in that order — locking monitors first
      # here would invert the order and deadlock a concurrent sync or re-upgrade.
      @user.with_lock do
        @user.monitors.where(id: keep).where(status: "suspended").find_each(&:reactivate!)
        active_scope.where.not(id: keep).find_each(&:suspend!)
        @user.clear_downgrade_choice!
      end
      Result.new(true, nil)
    end

    # Involuntary path: suspends the newest over-cap monitors (keeps the oldest,
    # deterministic) so a webhook-driven cancellation can't leave free users
    # monitoring 100 things. Idempotent.
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

      def cancel_subscription!
        @user.cancel_pro_subscription!
      end
  end
end
