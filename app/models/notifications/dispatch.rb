module Notifications
  # Coordinator: take a Notification row and deliver it over the channel(s) its
  # `channel` value selects. The Monitor operations create the Notification and
  # hand it here; Dispatch owns only the channel selection, never the email
  # specifics (that's the EmailChannel command + MonitorMailer).
  class Dispatch
    # channel value -> command class. Additive for V2 (e.g. "webhook").
    CHANNELS = { "email" => EmailChannel }.freeze

    def initialize(notification)
      @notification = notification
    end

    def deliver
      # Channel selection stays synchronous: an unknown channel is a programming
      # error and must blow up in the caller's stack, not after commit.
      channel_class = CHANNELS.fetch(@notification.channel)

      # …but the delivery itself waits for the caller's transaction to commit.
      # Some paths dispatch from inside one (the Stripe webhook and choose-N
      # reactivation run flag_missed!/check_in! inside ProcessedEvent.record_once),
      # and Solid Queue lives in a SEPARATE database: a job enqueued pre-commit
      # can be claimed by a worker that can't see the rows yet — a permanent
      # DeserializationError, which Active Job does not retry — and a rollback
      # (the designed Stripe-retry path) leaves an orphan job plus a Notification
      # row falsely stamped delivered. Deferring here rather than in the channel
      # gives every channel the same guarantee, V2 webhook channels included
      # (an outbound HTTP POST from inside an open transaction is the same bug).
      # With no transaction open this runs inline, so the ping paths — which
      # already dispatch outside their with_lock — are unchanged.
      ActiveRecord.after_all_transactions_commit do
        channel_class.new(@notification).deliver
      end
    end
  end
end
