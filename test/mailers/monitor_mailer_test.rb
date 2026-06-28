require "test_helper"

class MonitorMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers
  def default_url_options = { host: "example.com" }

  setup { @monitor = monitors(:up) }

  # Scenario 27 — down email renders with name, expected-by, detail link, to owner.
  test "down renders with the monitor name, expected-by time, and detail link" do
    @monitor.update!(next_due_at: 1.hour.ago)
    mail = MonitorMailer.down(@monitor)

    assert_equal [ @monitor.user.email_address ], mail.to
    assert_match @monitor.name, mail.subject
    body = mail.body.encoded
    assert_match @monitor.name, body
    assert_match monitor_url(@monitor), body
    # Expected-by = next_due_at + grace, rendered in the body.
    assert_match @monitor.due_with_grace_at.utc.strftime("%Y-%m-%d %H:%M"), body
  end

  # Scenario 28 — recovered email renders and is addressed to the owner.
  test "recovered renders and is delivered to the owner" do
    mail = MonitorMailer.recovered(@monitor)

    assert_equal [ @monitor.user.email_address ], mail.to
    assert_match @monitor.name, mail.subject
    assert_match @monitor.name, mail.body.encoded
    assert_match monitor_url(@monitor), mail.body.encoded
  end
end
