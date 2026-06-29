class User
  # The gated "choose your 5" downgrade (PRD §5.6) as an operation owned by the
  # user, reached via user.downgrade_to_free!(keep_ids:). Closes the "go Pro → add
  # 100 → cancel → keep 100" loophole: a user over the Free cap must pick exactly
  # FREE_PLAN_MONITOR_LIMIT monitors to keep active; the rest are plan-suspended
  # (retained, uncounted) — never deleted. Only after the choice do we cancel the
  # Stripe subscription, after which the verified webhook flips plan → free.
  #
  # An over-cap account is also driven here involuntarily (card failure / Portal
  # cancel): #enforce_free_cap! suspends the over-cap monitors immediately so there
  # is never silent free monitoring, leaving the account in the locked choose-5
  # state until the user confirms which 5 to keep.
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
