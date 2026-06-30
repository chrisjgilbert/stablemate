require "application_system_test_case"

# Edit (S17) and delete (S18) monitor flows — browser-driven end-to-end paths
# that the controller tests prove at the request level but cannot verify in the UI.
class MonitorEditDeleteTest < ApplicationSystemTestCase
  setup do
    @alice   = users(:alice)
    @monitor = monitors(:up)
  end

  # S17 — edit: rename a monitor through the form; the detail page reflects the new name.
  test "S17: editing a monitor name persists and the detail page shows the updated name" do
    sign_in @alice
    visit monitor_path(@monitor)

    click_on "Edit"
    assert_current_path edit_monitor_path(@monitor)

    fill_in "Name", with: "Renamed monitor"
    click_on "Save changes"

    assert_current_path monitor_path(@monitor)
    assert_text "Renamed monitor"
  end

  # S18 — delete: confirm the dialog; the monitor is gone and the dashboard shows
  # the empty state (alice's remaining fixtures are wiped before signing in).
  test "S18: deleting a monitor removes it and redirects to the dashboard" do
    @alice.monitors.where.not(id: @monitor.id).delete_all
    sign_in @alice
    visit monitor_path(@monitor)

    accept_confirm { click_on "Delete" }

    assert_current_path monitors_path
    assert_not @alice.monitors.exists?(@monitor.id)
  end
end
