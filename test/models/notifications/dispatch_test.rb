require "test_helper"

# Scenario 29 — Dispatch routes to a channel; EmailChannel sets delivered_at.
class Notifications::DispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup { @monitor = monitors(:up) }

  test "delivering an email notification enqueues the mailer and stamps delivered_at" do
    notification = @monitor.notifications.create!(channel: "email", event: "down")

    assert_enqueued_emails 1 do
      Notifications::Dispatch.new(notification).deliver
    end

    assert notification.reload.delivered_at.present?
  end

  test "an unknown channel raises rather than silently dropping the alert" do
    notification = @monitor.notifications.create!(channel: "carrier_pigeon", event: "down")
    assert_raises(KeyError) { Notifications::Dispatch.new(notification).deliver }
  end

  test "the Channel contract demands #deliver" do
    assert_raises(NotImplementedError) do
      Notifications::Channel.new(Notification.new).deliver
    end
  end
end
