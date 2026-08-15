require "application_system_test_case"

# The monitor lifecycle once config is code (v1-scope §12, first bullet). What a
# user may still do to a monitor in the browser is *operational* — pause it,
# delete it — and what they may no longer do is *configure* it: creation and
# editing both left for `stablemate:sync` (§3.1, §3.3).
#
# This replaces the edit half of the old monitor_edit_delete_test.rb. The delete
# half survives verbatim, because delete is still a browser flow — and under §11
# it is now load-bearing, being half of the only remedy a frozen `manual-<id>`
# row has. (Pause/resume, the other surviving operational verb, stays where it
# already was: monitors_test.rb's S4.)
class MonitorLifecycleTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @monitor = monitors(:up)
  end

  # --- What the browser may still do -----------------------------------------

  # Delete is the surviving write, and §11 makes it load-bearing: for a frozen
  # `manual-<id>` row, delete-and-redeclare is the ONLY way to change settings.
  test "a monitor can be deleted, which is half the remedy for a frozen row" do
    @alice.monitors.where.not(id: @monitor.id).delete_all
    sign_in @alice
    visit monitor_path(@monitor)

    accept_confirm { click_on "Delete" }

    assert_current_path monitors_path
    assert_not @alice.monitors.exists?(@monitor.id)
  end

  # --- What it may no longer do ----------------------------------------------

  # NOT `assert_no_link "Edit"` — §8 flags exactly that shape as an assertion
  # that stays green while proving nothing once the surface is gone. The route
  # not existing is the fact; the missing affordance is a consequence of it.
  test "the edit route does not exist" do
    # The helper is gone entirely, not merely un-generatable — `only:` never
    # defines it. Asserting on recognize_path too, because a helper can be absent
    # while the path still routes.
    assert_not respond_to?(:edit_monitor_path)
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/monitors/#{@monitor.id}/edit", method: :get)
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/monitors/#{@monitor.id}", method: :patch)
    end
  end

  test "the create route does not exist" do
    assert_not respond_to?(:new_monitor_path)
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/monitors", method: :post)
    end

    # `/monitors/new` still RECOGNISES — with `only:`, it falls through to `show`
    # with id="new" — so the fact worth pinning is where it lands. `set_monitor`
    # scopes through current_user.monitors, so the find raises RecordNotFound and
    # a bookmarked create URL is an opaque 404, not a form and not a 500.
    assert_equal({ controller: "monitors", action: "show", id: "new" },
                 Rails.application.routes.recognize_path("/monitors/new", method: :get))
  end

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

  # The backfilled population has no config writer at all — no form, no sync
  # entry, and (after §3.3) no transfer. §11 requires the panel to SAY so rather
  # than leave the owner of a pre-CLI monitor to discover it.
  test "a backfilled monitor is told its config is frozen and how to unfreeze it" do
    @monitor.update!(registration_key: "manual-#{@monitor.id}", source: "manual")
    sign_in @alice
    visit monitor_path(@monitor)

    within "[data-testid='config-panel']" do
      assert_text "1h"
      # The gem sentence is a lie for this row — nothing in a repo defines it and
      # no API key syncs it — so the panel must not claim it.
      assert_no_text "Defined in your repo"
      # The remedy, stated: delete it and declare the same work in c.monitors.
      assert_text "c.monitors"
    end
  end
end
