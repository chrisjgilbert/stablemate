require "application_system_test_case"

# The monitor lifecycle once config is code (v1-scope §12, first bullet). What a
# user may still do to a monitor in the browser is *operational* — pause it,
# delete it — and what they may no longer do is *configure* it: creation and
# editing both left for `stablemate:sync` (§3.1, §3.3).
#
# This replaces the edit half of the old monitor_edit_delete_test.rb. The delete
# half survives verbatim, because delete is still a browser flow. Pause/resume,
# the other surviving operational verb, stays where it already was:
# monitors_test.rb's S4; and the assertions that the config ROUTES are gone live
# in monitors_controller_test.rb, since there is nothing to look at.
class MonitorLifecycleTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @monitor = monitors(:up)
  end

  # --- What the browser may still do -----------------------------------------

  # Delete is the surviving write, and §11 leans on it: delete-and-redeclare is
  # how a pre-CLI `manual-<id>` row moves onto a name the repo chooses.
  test "a monitor can be deleted" do
    @alice.monitors.where.not(id: @monitor.id).delete_all
    sign_in @alice
    visit monitor_path(@monitor)

    accept_confirm { click_on "Delete" }

    assert_current_path monitors_path
    assert_not @alice.monitors.exists?(@monitor.id)
  end

  # --- What it may no longer do ----------------------------------------------

  # §12's "browser: onboarding" bullet, second half: no surface offers monitor
  # creation. Asserted by walking the pages a user actually lands on rather than
  # by a `refute_link` on one of them — §8 flags the single-page version as an
  # assertion that stays green while proving nothing.
  test "no page a user lands on offers monitor creation" do
    sign_in @alice
    project = @alice.projects.sole

    # `has_no_*`, not `!has_*`: the negative predicates return as soon as the
    # element is absent, where the positive ones wait out the full Capybara
    # timeout on every page that is already correct. Twelve such waits is a
    # minute of nothing.
    offenders = [ monitors_path, projects_path, project_path(project), monitor_path(@monitor) ]
      .reject do |path|
        visit path
        has_no_link?("New monitor") && has_no_link?("Add a monitor") &&
          has_no_selector?("form[action='#{monitors_path}'][method='post']")
      end

    assert_empty offenders, "these pages still offer monitor creation"
  end

  # --- Config is read-only, and says whose it is ------------------------------

  # §3.3: the show page renders read-only config "with its source named", and the
  # copy branches on `source` — because §8's backfill leaves a permanent `manual`
  # population that is not defined in any repo, for which the gem sentence is a
  # lie.
  test "a gem-registered monitor names the repo as the owner of its config" do
    gem_monitor = monitors(:gem_synced)
    gem_monitor.update!(last_synced_app: "my-app")
    sign_in @alice
    visit monitor_path(gem_monitor)

    within "[data-testid='config-panel']" do
      assert_text "1d"             # interval, read-only
      assert_text "1h"             # grace, read-only
      assert_text "stablemate:sync"
      assert_text "my-app"
      assert_no_field "monitor[expected_interval_seconds]"
    end
  end

  # §11: the panel may render the cron string when the column is present — but it
  # must never PROMISE from it, because detection stays interval-based in V1.
  test "a synced cron task shows its schedule without promising from it" do
    gem_monitor = monitors(:gem_synced)
    gem_monitor.update!(last_synced_app: "my-app", schedule: "0 9 * * 1-5")
    sign_in @alice
    visit monitor_path(gem_monitor)

    within "[data-testid='config-panel']" do
      assert_text "0 9 * * 1-5"
      # Interval-based detection cannot honour a cron, so the panel never claims
      # a cron-derived next run. That claim waits for cron-aware detection.
      assert_no_text "Friday"
    end
  end

  # The backfilled population has no config writer BY DEFAULT — no form, no
  # DERIVED sync entry, and (after §3.3) no transfer. §11 requires the panel to
  # say so rather than leave the owner of a pre-CLI monitor to discover it.
  test "a backfilled monitor is told nothing declares it, and how to change that" do
    @monitor.update!(registration_key: "manual-#{@monitor.id}", source: "manual")
    sign_in @alice
    visit monitor_path(@monitor)

    within "[data-testid='config-panel']" do
      assert_text "1h"
      # The gem sentence is a lie for this row — nothing in a repo defines it and
      # no API key syncs it — so the panel must not claim it.
      assert_no_text "Defined in your repo"
      # The route out, stated, and naming the key the user has to declare.
      assert_text "c.monitors"
      assert_text "manual-#{@monitor.id}"
      # NOT "can no longer be changed": a sync entry naming this key adopts the
      # row and updates it in place, so the panel must not push the owner into
      # deleting a monitor — and its whole history — to change an interval.
      assert_no_text "can no longer be changed"
    end
  end

  # A retired monitor's task is absent from the repo BY DEFINITION — that is why
  # it was pruned — so the gem panel's "edit it where it lives and deploy" would
  # point at a file that no longer contains it, and contradict the dashboard.
  test "a retired monitor is told to restore the task, not to edit it in the repo" do
    retired = monitors(:gem_synced)
    retired.update!(last_synced_app: "my-app")
    retired.retire!
    sign_in @alice
    visit monitor_path(retired)

    within "[data-testid='config-panel']" do
      assert_text "No longer declared"
      assert_text "Restore the task"
      assert_no_text "the next sync applies the change"
    end
  end
end
