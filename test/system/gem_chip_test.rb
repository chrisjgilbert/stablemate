require "application_system_test_case"

class GemChipTest < ApplicationSystemTestCase
  setup { sign_in users(:alice) }

  # S14 — a gem-sourced monitor shows the gem chip on its dashboard row and the
  # "synced from gem" chip on its detail header; a manual monitor shows neither.
  test "gem monitors show the gem chip; manual monitors do not" do
    gem_monitor = monitors(:gem_synced)
    manual_monitor = monitors(:up)

    visit monitors_path
    within "##{dom_id(gem_monitor, :row)}" do
      assert_text "gem"
    end
    within "##{dom_id(manual_monitor, :row)}" do
      assert_no_text "gem"
    end

    visit monitor_path(gem_monitor)
    assert_text "synced from gem"

    visit monitor_path(manual_monitor)
    assert_no_text "synced from gem"
  end
end
