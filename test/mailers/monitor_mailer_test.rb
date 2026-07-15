require "test_helper"

class MonitorMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers
  def default_url_options = { host: "example.com", protocol: "https" }

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

  # Error notices (job-failure-details.md §8) — a reported_error incident gets
  # its own copy: "reported an error" subject, body led by the error text.
  test "down with a reported_error incident renders the error in HTML and text" do
    incident = @monitor.incidents.create!(
      started_at: Time.current, cause: "reported_error",
      error: "ActiveRecord::Deadlocked: deadlock detected"
    )
    mail = MonitorMailer.down(@monitor, incident:)

    assert_equal [ @monitor.user.email_address ], mail.to
    assert_equal "#{@monitor.name} reported an error", mail.subject
    [ mail.html_part.body.decoded, mail.text_part.body.decoded ].each do |body|
      assert_match "ActiveRecord::Deadlocked: deadlock detected", body
      assert_match monitor_url(@monitor), body
      # For a reported error we ARE the log's headline — the "check your job
      # logs" sentence only survives in the missed-ping branch.
      assert_no_match(/Check your job logs/i, body)
    end
  end

  # §12-D — the subject never carries the error text (header-injection surface,
  # lock-screen previews).
  test "the reported-error subject carries only the monitor name, never the error" do
    incident = @monitor.incidents.create!(
      started_at: Time.current, cause: "reported_error", error: "secret database url leaked"
    )
    mail = MonitorMailer.down(@monitor, incident:)

    assert_no_match(/secret/, mail.subject)
  end

  # §10 — error text is untrusted input, rendered only via default ERB escaping.
  test "error text is HTML-escaped in the down email" do
    incident = @monitor.incidents.create!(
      started_at: Time.current, cause: "reported_error", error: "<script>alert(1)</script>"
    )
    mail = MonitorMailer.down(@monitor, incident:)

    html = mail.html_part.body.decoded
    assert_no_match(/<script>/, html)
    assert_match "&lt;script&gt;", html
  end

  test "down with a missed_ping incident keeps today's copy" do
    @monitor.update!(next_due_at: 1.hour.ago)
    incident = @monitor.incidents.create!(started_at: Time.current, cause: "missed_ping")
    mail = MonitorMailer.down(@monitor, incident:)

    assert_equal "#{@monitor.name} missed its check-in", mail.subject
    assert_match(/Check your job logs/i, mail.html_part.body.decoded)
  end

  # A nil incident degrades to the missed-ping copy, defensively.
  test "down with no incident degrades to the missed-ping copy" do
    @monitor.update!(next_due_at: 1.hour.ago)
    mail = MonitorMailer.down(@monitor)

    assert_equal "#{@monitor.name} missed its check-in", mail.subject
    assert_match(/Check your job logs/i, mail.html_part.body.decoded)
  end

  # Subject and body share ONE discriminator (the incident's cause) — a
  # reported_error incident renders the error copy even if its error text is
  # somehow blank, never the self-contradicting "reported an error" subject
  # over a "missed its check-in" body.
  test "down with a blank-error reported_error incident keeps the error copy" do
    incident = @monitor.incidents.create!(
      started_at: Time.current, cause: "reported_error", error: nil
    )
    mail = MonitorMailer.down(@monitor, incident:)

    assert_equal "#{@monitor.name} reported an error", mail.subject
    assert_no_match(/Check your job logs/i, mail.text_part.body.decoded)
    assert_no_match(/missed its expected check-in/i, mail.text_part.body.decoded)
  end

  # Deterministic under deliver_later: the missed-ping copy cites the incident's
  # start, not the live schedule — a failure ping on an already-down monitor
  # advances next_due_at, which would otherwise render a FUTURE "no ping
  # arrived by" time.
  test "down for a missed ping renders the incident's start, not the live schedule" do
    started = Time.utc(2026, 7, 15, 9, 0)
    incident = @monitor.incidents.create!(started_at: started, cause: "missed_ping")
    @monitor.update!(next_due_at: 2.hours.from_now)
    mail = MonitorMailer.down(@monitor, incident:)

    body = mail.text_part.body.decoded
    assert_includes body, "2026-07-15 09:00 UTC"
    refute_includes body, @monitor.due_with_grace_at.utc.strftime("%Y-%m-%d %H:%M UTC")
  end

  # EmailChannel passes incident: to every event, so recovered must accept (and
  # ignore) it.
  test "recovered accepts and ignores the incident kwarg" do
    incident = @monitor.incidents.create!(
      started_at: Time.current, cause: "reported_error", error: "boom"
    )
    mail = MonitorMailer.recovered(@monitor, incident:)

    assert_equal "#{@monitor.name} is back up", mail.subject
    assert_no_match(/boom/, mail.body.encoded)
  end

  # Scenario 28 — recovered email renders and is addressed to the owner.
  test "recovered renders and is delivered to the owner" do
    mail = MonitorMailer.recovered(@monitor)

    assert_equal [ @monitor.user.email_address ], mail.to
    assert_match @monitor.name, mail.subject
    assert_match @monitor.name, mail.body.encoded
    assert_match monitor_url(@monitor), mail.body.encoded
  end

  # Scenario 10 — down/recovered emails carry a configured From and render a detail
  # link whose host comes from config (default_url_options), not any request.
  test "down and recovered set a configured From address" do
    configured_from = ApplicationMailer.default[:from]
    assert configured_from.present?

    assert_equal configured_from, MonitorMailer.down(@monitor)[:from].value
    assert_equal configured_from, MonitorMailer.recovered(@monitor)[:from].value
  end

  test "detail link host comes from config, not the request" do
    config_host = Rails.application.config.action_mailer.default_url_options[:host]

    [ MonitorMailer.down(@monitor), MonitorMailer.recovered(@monitor) ].each do |mail|
      link = mail.body.encoded[/https?:\/\/[^\s"'<]+/]
      assert link, "expected a detail link in the email body"
      assert link.start_with?("https://"), "detail link must be https, got #{link}"
      assert_equal config_host, URI.parse(link).host
    end
  end
end
