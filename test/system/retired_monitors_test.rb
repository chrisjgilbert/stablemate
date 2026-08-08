require "application_system_test_case"

# The browser half of prune (v1-scope §6.1). A monitor whose task has left the
# repo's config is retired by `stablemate:sync PRUNE=1`: kept with its history,
# listed apart from the live ones, occupying no cap slot, and brought back only
# by a sync that sees the task again.
#
# The parallel `suspended` surface has the same test in billing_test.rb; this is
# its sibling, and CLAUDE.md requires the browser layer for a user-facing state
# rather than request-level assert_select alone.
class RetiredMonitorsTest < ApplicationSystemTestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  setup do
    # carol owns no monitors, so the cap counts here are only what this file makes.
    @user = users(:carol)
    @project = @user.projects.sole
  end

  test "a retired monitor is listed apart, uncounted, and cannot be paused back in" do
    live = @project.monitors.create!(name: "Nightly backup", **ATTRS)
    retired = @project.monitors.create!(name: "Old cron job", **ATTRS)
    retired.check_in! # a ping history the retirement must keep
    retired.retire!

    sign_in @user

    # The dashboard lists it under Retired, never among the active monitors.
    within "[data-testid='retired-section']" do
      assert_text "Old cron job"
      assert_no_text "Nightly backup"
    end
    assert_no_selector "[data-testid='retired-section'] [data-testid='next-check']"

    # Retiring is what frees the slot, so the header counts only the live one.
    assert_selector "[data-testid='monitor-count']", text: "1 / #{@user.monitor_limit}"
    assert_equal 1, @user.monitors.counting_toward_cap.count

    # The detail page offers neither control: pausing would take the freed slot
    # back, and resuming would undo a prune only a sync may undo.
    visit monitor_path(retired)
    assert_no_button "Pause"
    assert_no_button "Resume"

    # And the history is still there — retire never deletes.
    assert_equal 1, retired.ping_events.count
  end

  # The job's cron is still firing on a host that has not been redeployed. Neither
  # polarity of ping may resurrect it — FailureReport carries its own copy of the
  # guard, so a success-only check would pass a broken implementation.
  test "a stray ping of either polarity cannot resurrect a retired monitor" do
    retired = @project.monitors.create!(name: "Old cron job", **ATTRS)
    retired.retire!
    sign_in @user

    retired.check_in!
    retired.check_in!(kind: "failure", error: "boom")

    visit monitors_path
    within("[data-testid='retired-section']") { assert_text "Old cron job" }
    assert_predicate retired.reload, :retired?
    assert_empty retired.incidents
    assert_equal 0, @user.monitors.counting_toward_cap.count
  end

  # The task comes back in the repo and the next deploy's sync revives it — the
  # flow's actual ending, and the thing that makes retirement reversible.
  test "a sync that sees the task again brings the monitor back to the live list" do
    revived = @project.monitors.create!(name: "Old cron job", registration_key: "old_cron",
                                        source: "gem", last_synced_app: "my-app", **ATTRS)
    revived.check_in!
    revived.retire!
    sign_in @user
    within("[data-testid='retired-section']") { assert_text "Old cron job" }

    # Capybara cannot set an Authorization header, so the sync is driven
    # server-side and the page re-read — the same shape uptime_history_test uses.
    @project.sync_monitors(app: "my-app", declared_keys: %w[old_cron], entries: [
      { registration_key: "old_cron", name: "Old cron job", **ATTRS }
    ])

    visit monitors_path
    assert_no_selector "[data-testid='retired-section']"
    assert_text "Old cron job"
    assert_equal 1, @user.monitors.counting_toward_cap.count
  end
end
