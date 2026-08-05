require "test_helper"

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

  # F10 — the webhook / choose-N reactivation paths dispatch from inside an open
  # transaction. Solid Queue is a SEPARATE database, so an enqueue that lands
  # before the app transaction commits can be picked up by a worker that cannot
  # yet see the records: a permanent DeserializationError, with no retries. And
  # if the caller rolls back (the designed Stripe-retry path), the job is an
  # orphan pointing at rows that never existed.
  test "the mailer is enqueued only once the surrounding transaction commits" do
    notification = @monitor.notifications.create!(channel: "email", event: "down")

    assert_enqueued_emails 1 do
      ActiveRecord::Base.transaction do
        Notifications::Dispatch.new(notification).deliver

        # Nothing may be visible to a worker (separate queue DB) before commit…
        assert_no_enqueued_emails
        assert_nil notification.reload.delivered_at,
                   "delivered_at must not claim delivery for an enqueue that hasn't happened"
      end
    end

    assert notification.reload.delivered_at.present?
  end

  test "a rolled-back transaction leaves neither a mail job nor a delivered_at" do
    notification = @monitor.notifications.create!(channel: "email", event: "down")

    assert_no_enqueued_emails do
      ActiveRecord::Base.transaction do
        Notifications::Dispatch.new(notification).deliver
        raise ActiveRecord::Rollback
      end
    end

    assert_nil notification.reload.delivered_at
  end

  test "with no surrounding transaction the dispatch happens immediately" do
    notification = @monitor.notifications.create!(channel: "email", event: "down")

    Notifications::Dispatch.new(notification).deliver

    assert_enqueued_emails 1
    assert notification.delivered_at.present?, "the in-memory record is stamped, not just the row"
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
