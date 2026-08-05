require "test_helper"

# Pay is wrapped; we drive the mirror directly (no Stripe API).
class User::SubscriptionTest < ActiveSupport::TestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  setup do
    # carol owns no monitors, so this file's counts are only what it creates.
    @user = users(:carol)
    @project = @user.projects.sole
  end

  test "subscribed_to_pro? reflects the active Pay subscription mirror" do
    with_billing_enabled do
      refute @user.subscribed_to_pro?
      give_pro_subscription!
      assert @user.reload.subscribed_to_pro?
    end
  end

  # F5 — the two questions must stay separate. "Does Stripe still consider this
  # billable?" (live_pro_subscription?) is true for every non-terminal status;
  # "should the plan be Pro?" (subscribed_to_pro?) is deliberately narrower, so a
  # past_due account still drops to Free while its subscription stays cancellable
  # and blocks a second checkout.
  test "live_pro_subscription? covers non-terminal statuses subscribed_to_pro? does not" do
    with_billing_enabled do
      refute @user.live_pro_subscription?

      give_pro_subscription!(status: "past_due")
      @user.reload

      assert @user.live_pro_subscription?
      refute @user.subscribed_to_pro?
      assert_equal "free", @user.tap(&:sync_plan_from_subscription!).plan
    end
  end

  # The single "is there a Pro here?" question, so the downgrade copy, the billing
  # page's affordances and every Upgrade CTA cannot drift apart. It has to answer
  # YES for past_due — plan Free, Stripe still dunning.
  test "billed_for_pro? is true whenever Stripe could still charge for Pro" do
    with_billing_enabled do
      refute @user.billed_for_pro?, "a Free account with no subscription owes nothing"

      give_pro_subscription!(status: "past_due")
      assert @user.reload.billed_for_pro?, "mid-dunning is still being billed"

      @user.pay_subscriptions.update_all(status: "canceled")
      refute @user.reload.billed_for_pro?

      @user.update!(plan: "pro")
      assert @user.billed_for_pro?, "an active Pro plan counts even if the mirror drifts"
    end
  end

  # A first payment that never completed has charged nothing and expires on its
  # own, so the user must stay free to retry — the same relaxation
  # live_pro_subscription? makes for CheckoutsController.
  test "billed_for_pro? ignores a first payment that never completed" do
    with_billing_enabled do
      give_pro_subscription!(status: "incomplete")

      refute @user.reload.billed_for_pro?
      assert @user.can_upgrade_to_pro?, "they must be able to try paying us again"
    end
  end

  # The eligibility rule EVERY upgrade CTA reads. It was plan-only, so all four
  # offered a past_due user a button that bounced off CheckoutsController with
  # "You're already on Pro."
  test "can_upgrade_to_pro? refuses an account Stripe is still billing" do
    with_billing_enabled do
      give_pro_subscription!(status: "past_due")
      @user.reload

      assert_equal "free", @user.plan
      refute @user.can_upgrade_to_pro?, "the CTA must not promise what checkout will refuse"
    end
  end

  test "live_pro_subscription? ignores terminal subscriptions" do
    with_billing_enabled do
      give_pro_subscription!(status: "canceled")
      refute @user.reload.live_pro_subscription?

      @user.pay_subscriptions.update_all(status: "incomplete_expired")
      refute @user.reload.live_pro_subscription?
    end
  end

  # §12-J — an involuntary over-cap drop to Free starts a GRACE window and suspends
  # NOTHING: every monitor keeps running while the user is asked to pick their N. A
  # payment blip must never silently stop monitoring.
  test "sync to free over the cap starts a grace window and suspends nothing" do
    with_billing_enabled do
      freeze_time do
        @user.update!(plan: "pro")
        monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

        @user.sync_plan_from_subscription!
        @user.reload

        assert_equal "free", @user.plan
        # Nothing suspended — all monitors still count during the window.
        assert_equal 0, @user.monitors.where(status: "suspended").count
        assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT + 2, @user.monitors.counting_toward_cap.count
        monitors.each { |m| refute m.reload.suspended? }

        assert @user.awaiting_downgrade_choice?
        assert_in_delta Stablemate::DOWNGRADE_GRACE_PERIOD.from_now, @user.downgrade_choice_deadline_at, 1.second
      end
    end
  end

  # WU-6 (M5) / §12-J — an involuntary drop to Free over the cap locks the account
  # into a choose-N decision (a real flag + deadline), not silently keeping the
  # oldest N with no recourse. During grace nothing is suspended.
  test "an involuntary drop to free over the cap locks the account into a choose-N decision" do
    with_billing_enabled do
      freeze_time do
        @user.update!(plan: "pro")
        (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

        @user.sync_plan_from_subscription! # no active sub ⇒ free
        @user.reload

        assert @user.awaiting_downgrade_choice?
        assert @user.must_choose_downgrade?
        assert_in_delta Stablemate::DOWNGRADE_GRACE_PERIOD.from_now, @user.downgrade_choice_deadline_at, 1.second
        # Grace: every monitor still counts — none suspended during the window.
        assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT + 2, @user.monitors.counting_toward_cap.count
      end
    end
  end

  # A repeat cancel webhook while already awaiting must NOT push the deadline out —
  # the user gets one fixed window, not a rolling one.
  test "a repeat free sync does not extend the grace deadline" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

      @user.sync_plan_from_subscription!
      first_deadline = @user.reload.downgrade_choice_deadline_at

      travel 2.days do
        @user.sync_plan_from_subscription! # a later webhook, still over-cap on Free
      end

      assert_equal first_deadline, @user.reload.downgrade_choice_deadline_at
    end
  end

  test "re-upgrading to pro clears the choose-N lock and its deadline" do
    with_billing_enabled do
      @user.update!(plan: "free", awaiting_downgrade_choice: true, downgrade_choice_deadline_at: 3.days.from_now)
      give_pro_subscription!

      @user.sync_plan_from_subscription! # active sub ⇒ pro

      assert_equal "pro", @user.reload.plan
      refute @user.awaiting_downgrade_choice?
      refute @user.must_choose_downgrade?
      assert_nil @user.downgrade_choice_deadline_at
    end
  end

  test "resolve_downgrade_choice! reactivates the chosen, suspends the rest, clears the lock" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      @user.sync_plan_from_subscription! # ⇒ free, awaiting, grace (nothing suspended)
      assert @user.reload.must_choose_downgrade?

      # Re-pick the LAST N — during grace all are active; resolve suspends the rest.
      keep = monitors.last(Stablemate::FREE_PLAN_MONITOR_LIMIT).map(&:id)
      result = @user.resolve_downgrade_choice!(keep_ids: keep)

      assert result.ok?
      refute @user.reload.awaiting_downgrade_choice?
      assert_nil @user.downgrade_choice_deadline_at
      assert_equal keep.sort, @user.monitors.counting_toward_cap.ids.sort
      assert_equal 2, @user.monitors.where(status: "suspended").count
    end
  end

  test "resolve_downgrade_choice! with the wrong count is rejected and keeps the lock" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      @user.sync_plan_from_subscription!

      result = @user.resolve_downgrade_choice!(keep_ids: [ monitors.first.id ]) # too few

      refute result.ok?
      assert @user.reload.awaiting_downgrade_choice?
    end
  end

  # WU-6 review follow-up — a locked user who deletes monitors back within the Free
  # cap must not be stranded: the lock lifts and the survivors reactivate.
  test "the choose-N lock releases when the account drops back within the Free cap" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
      @user.sync_plan_from_subscription! # locked, grace (nothing suspended)
      assert @user.reload.must_choose_downgrade?

      @user.monitors.counting_toward_cap.order(:created_at).limit(3).each(&:destroy)

      @user.release_downgrade_lock_if_within_cap!

      refute @user.reload.awaiting_downgrade_choice?
      refute @user.must_choose_downgrade?
      assert_nil @user.downgrade_choice_deadline_at
      assert_equal 0, @user.monitors.where(status: "suspended").count
    end
  end

  # M3 — a voluntary choose-N downgrade can race its own cancel webhook: the webhook
  # lands between the Stripe cancel and the suspends, still sees every monitor
  # active, and opens an involuntary lock the user has in fact already answered.
  # Counting suspended monitors toward the cap kept the account "over cap" forever.
  test "the choose-N lock releases once suspensions put the account within the cap" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      monitors = (Stablemate::FREE_PLAN_MONITOR_LIMIT + 2).times.map { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

      # The racing cancel webhook, seeing the pre-suspension counts.
      @user.sync_plan_from_subscription!
      assert @user.reload.must_choose_downgrade?

      # The user's own choice completes: the unchosen monitors are suspended.
      monitors.last(2).each(&:suspend!)

      @user.release_downgrade_lock_if_within_cap!

      refute @user.reload.awaiting_downgrade_choice?
      assert_nil @user.downgrade_choice_deadline_at
      # Their choice stands — no cap slots are free, so nothing is reactivated.
      assert_equal Stablemate::FREE_PLAN_MONITOR_LIMIT, @user.monitors.counting_toward_cap.count
      assert_equal 2, @user.monitors.where(status: "suspended").count
    end
  end

  test "restore_suspended_monitors! reactivates only up to the available Pro slots" do
    with_billing_enabled do
      @user.update!(plan: "pro")
      stub_const(Stablemate, :PRO_PLAN_MONITOR_LIMIT, 4) do
        active = 3.times.map { |i| @project.monitors.create!(name: "A#{i}", **ATTRS) }
        suspended = 3.times.map { |i| m = @project.monitors.create!(name: "S#{i}", **ATTRS); m.suspend!; m }

        @user.restore_suspended_monitors!

        # Only one slot free (4 cap - 3 active) ⇒ exactly one reactivated.
        assert_equal 4, @user.monitors.counting_toward_cap.count
        assert_equal 2, @user.monitors.where(status: "suspended").count
        assert active.all? { |m| !m.reload.suspended? }
        # The oldest suspended is the one restored.
        refute suspended.first.reload.suspended?
      end
    end
  end

  # Pay declares `has_many :pay_customers` with NO `dependent:` (verified in pay
  # 11.7), so a bare destroy leaves every pay_* row behind with a nil owner — card
  # and receipt data with no account, and the thing Pay's webhook handlers then
  # blow up on. User::Closure used to compensate at the call site, which meant the
  # invariant held only for callers going through close_account!: a console
  # `user.destroy` or a future admin path orphaned them silently. The cascade
  # belongs on the association, so it is true of every destroy — hence NO
  # close_account! here.
  #
  # A `canceled` subscription keeps this network-free: Pay's own
  # `before_destroy :cancel_if_active` would otherwise call Stripe. Cancelling
  # first is User::Closure's job and is tested there.
  test "destroying the user alone takes every pay_* row with it" do
    with_billing_enabled do
      subscription = give_pro_subscription!(status: "canceled")
      customer = subscription.customer
      payment_method = customer.payment_methods.create!(processor_id: "pm_#{SecureRandom.hex(4)}",
        payment_method_type: "card", default: true, data: { brand: "Visa", last4: "4242" })
      charge = customer.charges.create!(processor_id: "ch_#{SecureRandom.hex(4)}",
        subscription: subscription, amount: 900, currency: "usd")

      @user.destroy!

      assert_not Pay::Customer.exists?(customer.id)
      assert_not Pay::Subscription.exists?(subscription.id)
      assert_not Pay::PaymentMethod.exists?(payment_method.id)
      assert_not Pay::Charge.exists?(charge.id)
    end
  end
end
