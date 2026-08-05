class User
  # Crucial invariant: `User.plan` is *derived* from the active Pay subscription
  # and is rewritten ONLY by #sync_plan_from_subscription!, which is called only
  # from Billing::WebhooksController after Stripe's signature is verified. No
  # controller, view, or client input ever sets `plan` directly. (PRD §12 security.)
  module Subscription
    extend ActiveSupport::Concern

    PRO_PRODUCT = "pro".freeze

    TERMINAL_STATUSES = %w[canceled incomplete_expired].freeze

    # `incomplete` means the first payment never completed — an abandoned or failed
    # SCA challenge — so nothing has been charged, and Stripe expires it to
    # `incomplete_expired` on its own within ~24h. Counting it as live would answer
    # a customer actively trying to pay us with "You're already on Pro." for a day.
    # It stays "live" for CANCELLATION, where tearing down a dangling attempt is
    # free and correct.
    UNBILLABLE_STATUSES = %w[incomplete].freeze

    included do
      pay_customer

      # Re-declare Pay's own associations, this time WITH the cascade. Pay 11.7
      # ships them with no `dependent:` option, so a plain `user.destroy` leaves
      # every pay_* row behind with a nil owner.
      #
      # The two `:through` associations have to be repeated verbatim after it:
      # redefining an association moves it to the END of the reflection hash, and
      # a has_many :through whose through-association is declared after it raises
      # HasManyThroughOrderError.
      has_many :pay_customers, class_name: "Pay::Customer", as: :owner, inverse_of: :owner,
        dependent: :destroy
      has_many :pay_charges, through: :pay_customers, class_name: "Pay::Charge", source: :charges
      has_many :pay_subscriptions, through: :pay_customers, class_name: "Pay::Subscription",
        source: :subscriptions

      # Pay reads the Stripe customer email from `owner.email`; Rails 8 auth stores it
      # as email_address.
      alias_attribute :email, :email_address

      scope :awaiting_downgrade_choice, -> { where(awaiting_downgrade_choice: true) }

      scope :downgrade_grace_expired, lambda {
        awaiting_downgrade_choice.where("downgrade_choice_deadline_at < ?", Time.current)
      }
    end

    def stripe_customer
      set_payment_processor(:stripe) unless payment_processor&.processor == "stripe"
      payment_processor
    end

    # Deliberately narrow (Pay's `active` scope): a past_due account drops to Free
    # by design, which is why this must not be used to answer "can they subscribe
    # again?" — see #live_pro_subscription?.
    def subscribed_to_pro?
      payment_processor&.subscribed?(name: PRO_PRODUCT) || false
    end

    # Does a Pro subscription Stripe could still bill exist? This — not
    # subscribed_to_pro? — is the question the Upgrade path must ask: a dunning
    # retry on the old subscription can succeed days later, so allowing a second
    # Checkout means two live Pro subscriptions and double billing.
    def live_pro_subscription?
      live_pro_subscriptions.where.not(status: UNBILLABLE_STATUSES).exists?
    end

    # "Is there a Pro here?" — the one question every Pro-facing surface asks, so
    # they cannot drift apart. Deliberately NOT `pro?`: a past_due account reads
    # Free by design while Stripe keeps dunning it, and every surface that asked
    # the plan instead got that user wrong in its own way.
    def billed_for_pro?
      pro? || live_pro_subscription?
    end

    # THE ONLY WRITER of `plan`. Returns true when the plan actually changed.
    #
    # Dropping to Free over the cap (involuntary downgrade — card failure or Portal
    # cancel) starts a GRACE window and suspends NOTHING — every monitor keeps
    # running while the user is asked to pick their N (§7 / §12-J). A payment blip
    # must never silently stop monitoring; the daily backstop settles the account
    # only if the window expires unanswered.
    def sync_plan_from_subscription!
      target = subscribed_to_pro? ? Plan::PRO : Plan::FREE
      changed = plan != target
      update!(plan: target) if changed

      if target == Plan::FREE
        # Guard on the flag so a repeat webhook never pushes the deadline out (one
        # window, not a rolling one).
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

    # Resolve the involuntary choose-N lock: the account already dropped to Free,
    # so this only re-picks which N monitors stay active — no Stripe call.
    def resolve_downgrade_choice!(keep_ids: [])
      Downgrade.new(self).resolve_choice!(keep_ids: keep_ids)
    end

    # The single place the grace window is closed. Idempotent so a repeat webhook
    # is a no-op.
    def clear_downgrade_choice!
      return unless awaiting_downgrade_choice?

      update!(awaiting_downgrade_choice: false, downgrade_choice_deadline_at: nil)
    end

    # The backstop the daily EnforceOverdueDowngradesJob runs per overdue record
    # once the grace window has expired unanswered.
    #
    # Re-read the record and re-check first: the job's batch is loaded once, so a
    # re-upgrade (or a choice the user just committed) landing mid-batch leaves us
    # holding a stale free+awaiting copy. over_free_cap_by is plan-blind, so acting
    # on it would suspend a *paying* Pro user's monitors until the next webhook.
    # The account may also have been CLOSED since the batch was loaded, in which
    # case the reload raises and there is nothing left to settle.
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

    # Lift the choose-N lock when the account is back within the Free cap. Without
    # this a user who dropped to <= FREE_PLAN_MONITOR_LIMIT while locked would be
    # stranded: the picker requires choosing exactly N, which they can no longer
    # satisfy.
    #
    # Counts only monitors occupying a cap slot, as every other cap decision does
    # (locked decision #8) — counting suspended ones kept an account that had
    # ALREADY settled itself looking permanently over cap.
    def release_downgrade_lock_if_within_cap!
      return unless free? && awaiting_downgrade_choice?
      return if over_free_cap_by.positive?

      restore_suspended_monitors!
      clear_downgrade_choice!
    end

    # The plan flip is left to the resulting webhook (the only writer of plan), so
    # the client and server can never drift. Every non-terminal subscription is
    # cancelled, not just the `active` one: a past_due subscription the user
    # downgrades away from must actually stop, or Stripe keeps dunning a customer
    # we've already suspended monitors for.
    def cancel_pro_subscription!
      live_pro_subscriptions.each(&:cancel_now!)
    end

    # Reactivate plan-suspended monitors (oldest first) up to the available Pro
    # slots.
    def restore_suspended_monitors!
      slots = remaining_monitor_slots
      return if slots <= 0

      scope = monitors.where(status: "suspended").order(:created_at)
      scope = scope.limit(slots) unless slots == Float::INFINITY
      scope.find_each(&:reactivate!)
    end

    # Driven by the explicit flag, not derived from over_free_cap_by (which stays
    # positive during grace, since nothing is suspended yet), so the lock persists
    # until the user re-picks, re-upgrades, or the backstop fires.
    def must_choose_downgrade?
      free? && awaiting_downgrade_choice?
    end

    private

    # Pay's own `active` scope is too narrow here — it excludes
    # past_due/unpaid/incomplete, which Stripe can still turn back into a charge —
    # so we exclude only the terminal statuses.
    def live_pro_subscriptions
      return Pay::Subscription.none unless payment_processor

      payment_processor.subscriptions.for_name(PRO_PRODUCT).where.not(status: TERMINAL_STATUSES)
    end
  end
end
