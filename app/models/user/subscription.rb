class User
  # Hosted-tier subscription state, wrapping the Pay gem (issue #19). We never
  # hand-roll subscription state — Pay owns the pay_* tables and Stripe is the
  # source of truth, reached only through verified webhooks.
  #
  # Crucial invariant: `User.plan` is *derived* from the active Pay subscription
  # and is rewritten ONLY by #sync_plan_from_subscription!, which is called only
  # from Billing::WebhooksController after Stripe's signature is verified. No
  # controller, view, or client input ever sets `plan` directly. (PRD §12 security.)
  module Subscription
    extend ActiveSupport::Concern

    PRO_PRODUCT = "pro".freeze

    # Pay::Subscription statuses that mean the subscription is over for good.
    # Everything else Stripe can still bill — `past_due` and `unpaid` are mid-
    # dunning and a retry may yet succeed, `incomplete` is awaiting a first
    # payment, `paused` resumes, `trialing`/`active` are obviously live. Only
    # `canceled` and `incomplete_expired` are terminal.
    TERMINAL_STATUSES = %w[canceled incomplete_expired].freeze

    # …but a subscription that has never taken a payment must not block the user
    # from trying again. `incomplete` means the first payment never completed —
    # an abandoned or failed SCA challenge — so nothing has been charged, and
    # Stripe expires it to `incomplete_expired` on its own within ~24h. Counting
    # it as live would answer a customer actively trying to pay us with "You're
    # already on Pro." for a day: a certain lost upgrade, guarding against a
    # double charge that cannot happen. It stays "live" for CANCELLATION, where
    # tearing down a dangling attempt is free and correct.
    UNBILLABLE_STATUSES = %w[incomplete].freeze

    included do
      # Make the User a Pay billable: pay_customers / subscriptions / charges.
      pay_customer

      # Pay reads the Stripe customer email from `owner.email`; Rails 8 auth stores it
      # as email_address.
      alias_attribute :email, :email_address

      # Accounts owing a choose-N decision after an involuntary drop to Free.
      scope :awaiting_downgrade_choice, -> { where(awaiting_downgrade_choice: true) }

      # Those whose grace window has elapsed — the daily EnforceOverdueDowngradesJob's
      # work set. Mirrors Monitoring::Monitor.overdue (a base scope + a temporal
      # predicate) so the job stays pure iteration.
      scope :downgrade_grace_expired, lambda {
        awaiting_downgrade_choice.where("downgrade_choice_deadline_at < ?", Time.current)
      }
    end

    # Find or create the user's default Stripe customer, ready for Checkout/Portal.
    def stripe_customer
      set_payment_processor(:stripe) unless payment_processor&.processor == "stripe"
      payment_processor
    end

    # Does Stripe currently consider this user actively subscribed to Pro? Reads
    # Pay's local mirror (kept current by webhooks) — not the client. Deliberately
    # narrow (Pay's `active` scope): a past_due account drops to Free by design,
    # which is why this must not be used to answer "can they subscribe again?" —
    # see #live_pro_subscription?.
    def subscribed_to_pro?
      payment_processor&.subscribed?(name: PRO_PRODUCT) || false
    end

    # Does a Pro subscription Stripe could still bill exist? True for every
    # non-terminal status, so a `past_due` subscription mid-dunning still counts.
    # This — not subscribed_to_pro? — is the question the Upgrade path must ask:
    # a dunning retry on the old subscription can succeed days later, so allowing
    # a second Checkout means two live Pro subscriptions and double billing (F5).
    def live_pro_subscription?
      live_pro_subscriptions.where.not(status: UNBILLABLE_STATUSES).exists?
    end

    # Recompute `plan` from the Pay subscription mirror and persist it. THE ONLY
    # writer of `plan`. Returns true when the plan actually changed.
    #   active Pro subscription ⇒ "pro";  none/cancelled ⇒ "free".
    #
    # Side effects keep monitors consistent with the new cap:
    #   * dropping to Free over the cap (involuntary downgrade — card failure or
    #     Portal cancel) starts a GRACE window and suspends NOTHING — every monitor
    #     keeps running while the user is asked to pick their N (§7 / §12-J). A
    #     payment blip must never silently stop monitoring; the daily backstop
    #     (EnforceOverdueDowngradesJob → #enforce_downgrade_fallback!) settles the
    #     account only if the window expires unanswered.
    #   * returning to Pro restores previously plan-suspended monitors (PRD §5.6:
    #     "if they re-upgrade later, suspended monitors can be reactivated"), up to
    #     the Pro cap.
    def sync_plan_from_subscription!
      target = subscribed_to_pro? ? Plan::PRO : Plan::FREE
      changed = plan != target
      update!(plan: target) if changed

      if target == Plan::FREE
        # Dropping to Free while over the cap is an INVOLUNTARY downgrade (card
        # failure / Portal cancel). Open a fixed grace window and lock the account
        # into a choose-N decision (WU-6) — but suspend nothing. Guard on the flag
        # so a repeat webhook never pushes the deadline out (one window, not a
        # rolling one); the flag is cleared by resolve_downgrade_choice!, a
        # re-upgrade, or the backstop once the deadline passes.
        if over_free_cap_by.positive? && !awaiting_downgrade_choice?
          update!(awaiting_downgrade_choice: true,
            downgrade_choice_deadline_at: Stablemate::DOWNGRADE_GRACE_PERIOD.from_now)
        end
      else
        restore_suspended_monitors!
        clear_downgrade_choice!
      end

      changed
    end

    # The gated "choose your 5" downgrade (PRD §5.6). Suspends the unchosen
    # monitors and cancels Stripe; the plan flip itself arrives by webhook.
    def downgrade_to_free!(keep_ids: [])
      Downgrade.new(self).to_free!(keep_ids: keep_ids)
    end

    # Resolve the involuntary choose-N lock (WU-6): the account already dropped to
    # Free, so this only re-picks which N monitors stay active — no Stripe call.
    def resolve_downgrade_choice!(keep_ids: [])
      Downgrade.new(self).resolve_choice!(keep_ids: keep_ids)
    end

    # Clear the choose-N lock AND its grace deadline. The single place the window
    # is closed — reached on re-upgrade, after the user commits a choice
    # (resolve_choice!), from release_downgrade_lock_if_within_cap!, and from the
    # backstop (enforce_downgrade_fallback!). Idempotent so a repeat webhook is a
    # no-op.
    def clear_downgrade_choice!
      return unless awaiting_downgrade_choice?

      update!(awaiting_downgrade_choice: false, downgrade_choice_deadline_at: nil)
    end

    # The backstop the daily EnforceOverdueDowngradesJob runs per overdue record
    # once the grace window has expired unanswered. Settles the account against the
    # Free cap: suspend the over-cap monitors (oldest FREE_PLAN_MONITOR_LIMIT kept),
    # then clear the choose-N flags. enforce_free_cap! is itself a no-op when the
    # account is already within the cap, so this is safe either way — after it runs
    # the account is settled, nothing left awaiting.
    #
    # Re-read the record and re-check first: the job's batch is loaded once, so a
    # re-upgrade (or a choice the user just committed) landing mid-batch leaves us
    # holding a stale free+awaiting copy. over_free_cap_by is plan-blind, so acting
    # on it would suspend a *paying* Pro user's monitors until the next webhook (F13).
    #
    # The account may also have been CLOSED since the batch was loaded
    # (User::Closure), in which case the reload raises. There is nothing left to
    # settle — the monitors went with it — so skip the record rather than let it
    # abandon everyone after it in the batch.
    def enforce_downgrade_fallback!
      begin
        reload
      rescue ActiveRecord::RecordNotFound
        return
      end

      return unless must_choose_downgrade?

      Downgrade.new(self).enforce_free_cap!
      clear_downgrade_choice!
    end

    # Lift the choose-N lock when the account is back within the Free cap — e.g. the
    # user deleted monitors while locked, or a voluntary choose-N downgrade already
    # suspended the difference. The account fits, so reactivate whatever the free
    # slots allow and clear the flag. Without this a user who dropped to <=
    # FREE_PLAN_MONITOR_LIMIT while locked would be stranded: the picker requires
    # choosing exactly N, which they can no longer satisfy.
    #
    # Count only monitors occupying a cap slot, as every other cap decision does
    # (locked decision #8) — counting suspended ones kept an account that had
    # ALREADY settled itself looking permanently over cap, so a voluntary downgrade
    # that raced its own cancel webhook into a spurious lock could never escape it
    # (M3). Idempotent; a no-op unless actually locked and within the cap.
    def release_downgrade_lock_if_within_cap!
      return unless free? && awaiting_downgrade_choice?
      return if over_free_cap_by.positive?

      restore_suspended_monitors!
      clear_downgrade_choice!
    end

    # Cancel the user's live Pro subscription(s) at Stripe (e.g. on downgrade). The
    # plan flip is left to the resulting webhook (the only writer of plan), so the
    # client and server can never drift. Pay coupling lives here, not in callers.
    # Every non-terminal subscription is cancelled, not just the `active` one: a
    # past_due subscription the user downgrades away from must actually stop, or
    # Stripe keeps dunning a customer we've already suspended monitors for (F5).
    def cancel_pro_subscription!
      live_pro_subscriptions.each(&:cancel_now!)
    end

    # Reactivate plan-suspended monitors (oldest first) up to the available Pro
    # slots. Reached on a re-upgrade. Each monitor re-evaluates its own heartbeat.
    def restore_suspended_monitors!
      slots = remaining_monitor_slots
      return if slots <= 0

      scope = monitors.where(status: "suspended").order(:created_at)
      scope = scope.limit(slots) unless slots == Float::INFINITY
      scope.find_each(&:reactivate!)
    end

    # True when the account owes a choose-N decision after an involuntary drop to
    # Free — driven by the explicit flag (WU-6), not derived from over_free_cap_by
    # (which stays positive during grace, since nothing is suspended yet), so the
    # lock persists until the user re-picks, re-upgrades, or the backstop fires.
    def must_choose_downgrade?
      free? && awaiting_downgrade_choice?
    end

    private

    # The user's still-billable Pro subscriptions per Pay's mirror. Pay's own
    # `active` scope is too narrow here — it excludes past_due/unpaid/incomplete,
    # which Stripe can still turn back into a charge — so we exclude only the
    # terminal statuses. Normally 0 or 1 rows; a relation because a pre-fix account
    # could have collected two.
    def live_pro_subscriptions
      return Pay::Subscription.none unless payment_processor

      payment_processor.subscriptions.for_name(PRO_PRODUCT).where.not(status: TERMINAL_STATUSES)
    end
  end
end
