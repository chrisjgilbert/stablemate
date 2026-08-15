require "application_system_test_case"

# S6 — the headline flow: outage → down email → recovery email, with the
# dashboard row badge flipping live (Turbo Stream over Solid Cable, no reload).
class OutageRecoveryTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  # Detection sweeps every monitor, so clear them all and create exactly one.
  setup do
    Monitoring::Monitor.delete_all
    @alice = users(:alice)
    @project = @alice.projects.sole
    @ping_key = issue_ping_key(@project)
  end

  # A registration_key is required now: it IS the address (v1-scope §3.2).
  def heartbeat(name)
    @project.monitors.create!(
      name: name, registration_key: name.parameterize.underscore, source: "gem",
      expected_interval_seconds: 3600, grace_period_seconds: 300
    )
  end

  test "S6: a monitor goes down (live) with a down email, then recovers with a recovery email" do
    monitor = heartbeat("Heartbeat job")

    sign_in @alice

    # Check in so it's Up — over the real endpoint, header auth and all.
    browser_check_in(monitor, ping_key: @ping_key)
    monitor.reload
    assert monitor.up?

    # Watching the dashboard, the row is Up.
    visit monitors_path
    assert_selector "##{dom_id(monitor, :row)}", text: "Up"

    ActionMailer::Base.deliveries.clear

    # Travel past interval + grace and run detection inline. The broadcast jobs
    # must run too, so the row flips live without a reload.
    travel_to monitor.due_with_grace_at + 1.minute do
      perform_enqueued_jobs do
        DetectMissedPingsJob.perform_now
      end
    end

    # The badge flips to Down on the already-loaded page (Turbo Stream).
    assert_selector "##{dom_id(monitor, :row)}", text: "Down"
    assert monitor.reload.down?

    # A down email was sent.
    assert_equal 1, ActionMailer::Base.deliveries.count { |m| m.subject.include?("missed its check-in") }

    ActionMailer::Base.deliveries.clear

    # Ping again → recovery. Run the broadcast + mailer jobs.
    perform_enqueued_jobs do
      browser_check_in(monitor, ping_key: @ping_key)
    end

    assert_selector "##{dom_id(monitor, :row)}", text: "Up"
    assert monitor.reload.up?
    assert_equal 1, ActionMailer::Base.deliveries.count { |m| m.subject.include?("is back up") }
  end

  # S6 (detail page) — the monitor-detail header badge flips live too (spec §3.8:
  # the detail header subscribes and updates over Solid Cable, no full reload).
  test "S6 detail: the detail-page badge flips to Down live when detection runs" do
    monitor = heartbeat("Detail watch")
    browser_check_in(monitor, ping_key: @ping_key)
    assert monitor.reload.up?

    sign_in @alice
    visit monitor_path(monitor)
    assert_selector "##{dom_id(monitor, :badge)}", text: "Up"

    travel_to monitor.due_with_grace_at + 1.minute do
      perform_enqueued_jobs do
        DetectMissedPingsJob.perform_now
      end
    end

    # The header badge updates without navigating away from the detail page.
    assert_selector "##{dom_id(monitor, :badge)}", text: "Down"
    assert monitor.reload.down?
  end
end
