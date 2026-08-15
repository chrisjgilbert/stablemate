require "application_system_test_case"

# Error notices (job-failure-details.md §11): an up monitor receives a failure
# check-in (`status=1&message=…`), flips down live on the dashboard, the down
# email carries the reported error, and the next successful check-in recovers it
# with a recovery email.
#
# Driven over the real endpoint via browser_check_in rather than monitor.check_in!
# — v1-scope §8 flags this file as one of the three that lose end-to-end coverage
# if they drop to the model when the credential moves into a header (§3.2).
class ErrorNoticesTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  # Detection sweeps every monitor, so clear them all and create exactly one.
  setup do
    Monitoring::Monitor.delete_all
    @alice = users(:alice)
    @project = @alice.projects.sole
    @ping_key = issue_ping_key(@project)
  end

  test "a failure ping flips the monitor down live, emails the error, then a success recovers it" do
    monitor = @project.monitors.create!(
      name: "Nightly backup", registration_key: "nightly_backup", source: "gem",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300
    )

    sign_in @alice

    # Check in so it's Up — over the real endpoint, header auth and all.
    browser_check_in(monitor, ping_key: @ping_key)
    assert monitor.reload.up?

    # Watching the dashboard, the row is Up.
    visit monitors_path
    assert_selector "##{dom_id(monitor, :row)}", text: "Up"

    ActionMailer::Base.deliveries.clear

    # The job reports a failure on an otherwise on-time ping. Run the enqueued
    # jobs so the mailer sends and the Turbo Stream broadcast reaches the page.
    perform_enqueued_jobs do
      browser_check_in(monitor, ping_key: @ping_key,
                       status: 1, message: "RuntimeError: backup disk full")
    end

    # The badge flips to Down on the already-loaded page (Turbo Stream) —
    # immediately, with no grace wait.
    assert_selector "##{dom_id(monitor, :row)}", text: "Down"
    assert monitor.reload.down?
    assert_equal "reported_error", monitor.incidents.open.sole.cause

    # One down email was sent, with the error-notice subject and the error text.
    down_email = ActionMailer::Base.deliveries.find { |m| m.subject.include?("reported an error") }
    assert down_email, "expected a 'reported an error' email"
    assert_includes down_email.text_part.body.decoded, "RuntimeError: backup disk full"

    # The detail page surfaces the cause: the banner leads with "reported an
    # error" (not the missed-ping copy), shows the error text itself, and the
    # recent-events feed carries the failure ping row.
    visit monitor_path(monitor)
    assert_selector "[data-testid=incident-banner]", text: "Monitor is down — the job reported an error"
    assert_selector "[data-testid=incident-error]", text: "RuntimeError: backup disk full"
    assert_selector "[data-testid=recent-events] li", text: "Error reported — RuntimeError: backup disk full"
    assert_selector "[data-testid=recent-events] li", text: "Went down — job reported an error"
    assert_no_text "no ping received"

    # Back to the dashboard to watch the recovery land live.
    visit monitors_path

    ActionMailer::Base.deliveries.clear

    # The next successful ping recovers it → one recovery email, badge flips back.
    perform_enqueued_jobs do
      browser_check_in(monitor, ping_key: @ping_key)
    end

    assert_selector "##{dom_id(monitor, :row)}", text: "Up"
    assert monitor.reload.up?
    assert_equal 1, ActionMailer::Base.deliveries.count { |m| m.subject.include?("is back up") }
  end
end
