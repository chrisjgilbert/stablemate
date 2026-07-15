require "application_system_test_case"

# Error notices (job-failure-details.md §11) — the manual-path flow: an up
# monitor receives a failure ping (`status=1&message=…`), flips down live on the
# dashboard, the down email carries the reported error, and the next successful
# ping recovers it with a recovery email.
class ErrorNoticesTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  # Detection sweeps every monitor, so clear them all and create exactly one.
  setup { Monitoring::Monitor.delete_all; @alice = users(:alice) }

  test "a failure ping flips the monitor down live, emails the error, then a success recovers it" do
    monitor = @alice.monitors.create!(
      name: "Nightly backup",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300
    )

    sign_in @alice

    # Ping it so it's Up.
    Capybara.using_session(:pinger) { visit ping_path(monitor.ping_token) }
    assert monitor.reload.up?

    # Watching the dashboard, the row is Up.
    visit monitors_path
    assert_selector "##{dom_id(monitor, :row)}", text: "Up"

    ActionMailer::Base.deliveries.clear

    # The job reports a failure on an otherwise on-time ping. Run the enqueued
    # jobs so the mailer sends and the Turbo Stream broadcast reaches the page.
    perform_enqueued_jobs do
      Capybara.using_session(:pinger) do
        visit ping_path(monitor.ping_token, status: 1, message: "RuntimeError: backup disk full")
      end
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

    ActionMailer::Base.deliveries.clear

    # The next successful ping recovers it → one recovery email, badge flips back.
    perform_enqueued_jobs do
      Capybara.using_session(:pinger) { visit ping_path(monitor.ping_token) }
    end

    assert_selector "##{dom_id(monitor, :row)}", text: "Up"
    assert monitor.reload.up?
    assert_equal 1, ActionMailer::Base.deliveries.count { |m| m.subject.include?("is back up") }
  end
end
