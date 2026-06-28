module Notifications
  # Command contract (CLAUDE.md Command-pattern exception): a uniform #deliver
  # over interchangeable alert channels. V1 ships one channel (email); webhook
  # channels are additive in V2 behind this same contract. This is the one place
  # a verb-shaped dispatch is allowed — see architecture.md §5.
  class Channel
    def initialize(notification)
      @notification = notification
    end

    def deliver
      raise NotImplementedError, "#{self.class} must implement #deliver"
    end
  end
end
