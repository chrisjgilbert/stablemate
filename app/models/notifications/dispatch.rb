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
      channel_class = CHANNELS.fetch(@notification.channel)
      channel_class.new(@notification).deliver
    end
  end
end
