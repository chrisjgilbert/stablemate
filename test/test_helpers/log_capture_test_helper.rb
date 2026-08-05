# Capture what the code under test writes to Rails.logger.
#
# Several tests assert on a logged warning as the observable outcome — an alert
# that swallows its delivery error, the prune job skipping an un-rolled day.
# Each was swapping Rails.logger for a StringIO and restoring it by hand.
module LogCaptureTestHelper
  # Returns everything logged inside the block as a string. Restores the previous
  # logger even if the block raises.
  def capturing_logs
    out = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(out)
    yield
    out.string
  ensure
    Rails.logger = original
  end
end
