module Notifications
  # Command contract (CLAUDE.md Command-pattern exception): a uniform #deliver
  # over interchangeable alert channels. This is the one place a verb-shaped
  # dispatch is allowed.
  class Channel
    def initialize(notification)
      @notification = notification
    end

    def deliver
      raise NotImplementedError, "#{self.class} must implement #deliver"
    end
  end
end
