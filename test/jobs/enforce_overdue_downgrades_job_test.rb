require "test_helper"

# EnforceOverdueDowngradesJob — the daily backstop for the involuntary-downgrade
# grace period (projects.md §7 / §12-J). Nothing is suspended during the window;
# only once a user's deadline passes unanswered does this job settle the account
# against the Free cap. The job orchestrates; User#enforce_downgrade_fallback!
# does the work (CLAUDE.md rule 5).
class EnforceOverdueDowngradesJobTest < ActiveJob::TestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  # carol and dave own no monitors — the grace/suspension counts here are only
  # what the test builds.
  setup { @user = users(:carol) }

  # Put a user in the grace state exactly as sync_plan_from_subscription! would:
  # over the Free cap, awaiting a choice, deadline set, nothing suspended.
  # Returns the monitors it created.
  #
  # `opens_at` moves when the WINDOW opens, and therefore when it expires — which
  # is how a second user can be set up as still inside their grace while @user's
  # has already run out.
  def start_grace!(monitor_count, user: @user, opens_at: Time.current)
    project = user.projects.sole
    monitors = nil
    with_billing_enabled do
      user.update!(plan: "pro")
      monitors = monitor_count.times.map { |i| project.monitors.create!(name: "M#{i}", **ATTRS) }
      travel_to(opens_at) { user.sync_plan_from_subscription! } # no active sub ⇒ free + grace
    end
    monitors
  end

  test "before the deadline it is a no-op — nothing suspended, flags intact" do
    monitors = start_grace!(FREE + 2)
    assert @user.reload.awaiting_downgrade_choice?

    # Still inside the window: the deadline has not passed.
    travel_to Stablemate::DOWNGRADE_GRACE_PERIOD.from_now - 1.day do
      EnforceOverdueDowngradesJob.perform_now
    end

    @user.reload
    assert @user.awaiting_downgrade_choice?
    assert @user.downgrade_choice_deadline_at.present?
    assert_equal 0, @user.monitors.where(status: "suspended").count
    assert_equal FREE + 2, @user.monitors.counting_toward_cap.count
    monitors.each { |m| refute m.reload.suspended? }
  end

  test "after the deadline over the cap it suspends the over-cap monitors and clears the flags" do
    monitors = start_grace!(FREE + 2)

    travel_to Stablemate::DOWNGRADE_GRACE_PERIOD.from_now + 1.hour do
      EnforceOverdueDowngradesJob.perform_now
    end

    @user.reload
    refute @user.awaiting_downgrade_choice?
    assert_nil @user.downgrade_choice_deadline_at
    assert_equal FREE, @user.monitors.counting_toward_cap.count
    assert_equal 2, @user.monitors.where(status: "suspended").count
    # The oldest FREE are kept; the newest 2 are suspended.
    monitors.first(FREE).each { |m| refute m.reload.suspended? }
    monitors.last(2).each { |m| assert m.reload.suspended? }
  end

  test "after the deadline within the cap it just clears the flags, suspending nothing" do
    # Over-cap grace, then the user deletes back within the Free cap before the deadline.
    monitors = start_grace!(FREE + 2)
    monitors.last(3).each(&:destroy) # FREE - 1 remain, within the cap

    travel_to Stablemate::DOWNGRADE_GRACE_PERIOD.from_now + 1.hour do
      EnforceOverdueDowngradesJob.perform_now
    end

    @user.reload
    refute @user.awaiting_downgrade_choice?
    assert_nil @user.downgrade_choice_deadline_at
    assert_equal 0, @user.monitors.where(status: "suspended").count
    assert_equal FREE - 1, @user.monitors.counting_toward_cap.count
  end

  # F13 — the job's batch is loaded once, so a re-upgrade webhook committing while
  # the batch is being walked leaves an in-memory record that still looks
  # free+awaiting. over_free_cap_by is plan-blind, so without a re-check the
  # backstop would suspend a *paying* Pro user's monitors until the next webhook.
  test "a record that re-upgraded mid-batch is left alone" do
    monitors = start_grace!(FREE + 2)

    travel_to Stablemate::DOWNGRADE_GRACE_PERIOD.from_now + 1.hour do
      # The record as the job loaded it: free, awaiting, deadline passed.
      stale = User.downgrade_grace_expired.find(@user.id)

      # Meanwhile the re-upgrade webhook commits: plan pro, lock cleared.
      User.where(id: @user.id).update_all(
        plan: "pro", awaiting_downgrade_choice: false, downgrade_choice_deadline_at: nil
      )

      stale.enforce_downgrade_fallback!
    end

    @user.reload
    assert_equal "pro", @user.plan, "the paying user's plan must not be touched"
    refute @user.awaiting_downgrade_choice?
    assert_equal 0, @user.monitors.where(status: "suspended").count
    monitors.each { |m| refute m.reload.suspended?, "a paying Pro user's monitor was suspended" }
  end

  # WS-D: accounts can now be closed, and the batch is loaded once. A user who
  # deletes their account while the job is walking the batch leaves a stale
  # in-memory record whose row is gone — enforce_downgrade_fallback! reloads
  # first, which would raise RecordNotFound and abandon everyone after them in
  # the batch.
  test "a record deleted mid-batch is skipped, and the rest of the batch still settles" do
    start_grace!(FREE + 2)
    other = users(:dave)
    other_monitors = start_grace!(FREE + 2, user: other)

    travel_to Stablemate::DOWNGRADE_GRACE_PERIOD.from_now + 1.hour do
      # The batch as the job loaded it, ordered so the doomed record is walked
      # first — the point is that everyone after it still gets settled.
      batch = User.downgrade_grace_expired.to_a.sort_by { |u| u.id == @user.id ? 0 : 1 }
      assert_equal 2, batch.size

      # Carol closes her account while the job is mid-batch.
      with_billing_disabled { @user.close_account! }

      assert_nothing_raised { batch.each(&:enforce_downgrade_fallback!) }
    end

    # The user after the deleted record still got settled.
    refute other.reload.awaiting_downgrade_choice?
    assert_equal 2, other_monitors.last(2).count { |m| m.reload.suspended? }
  end

  test "a user still within the window is left untouched even when another is overdue" do
    # Two users in grace: carol overdue, dave still inside their window. Only carol settles.
    overdue = start_grace!(FREE + 2)

    other = users(:dave)
    # Dave's window opens later, so their deadline is still in the future below.
    start_grace!(FREE + 1, user: other, opens_at: Stablemate::DOWNGRADE_GRACE_PERIOD.from_now - 2.days)

    travel_to Stablemate::DOWNGRADE_GRACE_PERIOD.from_now + 1.hour do
      EnforceOverdueDowngradesJob.perform_now
    end

    # Carol (overdue) settled; dave (still in window) untouched.
    refute @user.reload.awaiting_downgrade_choice?
    assert_equal 2, overdue.last(2).count { |m| m.reload.suspended? }
    assert other.reload.awaiting_downgrade_choice?
    assert_equal 0, other.monitors.where(status: "suspended").count
  end
end
