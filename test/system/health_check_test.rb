require "application_system_test_case"

# Phase 0 has no UI, so there is no user flow to drive yet. This trivial test
# exists only to prove the browser-driven system-test harness boots headless, so
# Phase 1 can write real flow tests immediately. (phase-0 spec §4)
class HealthCheckTest < ApplicationSystemTestCase
  test "the app boots and the health check responds" do
    visit "/up"

    # Rails' health check renders a bodyless page with a green background on 200.
    assert_selector "body[style*='green']", visible: :all
  end
end
