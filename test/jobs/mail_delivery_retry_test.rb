require "test_helper"
require "net/smtp"

# F1 — a transient SMTP failure must never silently discard an alert. Production
# raises delivery errors so a failed send fails the MailDeliveryJob; these tests
# pin the retry layer that then gets the alert delivered anyway, and pin that the
# retries are bounded (a permanently broken relay must stop, loudly, not loop).
class MailDeliveryRetryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Stand-in relay: raises a transient SMTP 4xx for the first `failures` sends,
  # then accepts. Registered as a real delivery method so the whole production
  # path runs — MailDeliveryJob -> Mail::Message#deliver -> delivery_method#deliver!.
  class FlakyRelay
    class << self
      attr_accessor :attempts, :failures
    end
    self.attempts = 0
    self.failures = 0

    def initialize(values)
      @settings = values
    end

    def deliver!(mail)
      self.class.attempts += 1
      raise Net::SMTPServerBusy, "450 4.7.1 Try again later" if self.class.attempts <= self.class.failures
      mail
    end
  end

  setup do
    @original_delivery_method  = ActionMailer::Base.delivery_method
    @original_raise_delivery   = ActionMailer::Base.raise_delivery_errors
    ActionMailer::Base.add_delivery_method :flaky_relay, FlakyRelay
    ActionMailer::Base.delivery_method = :flaky_relay
    # Production raises so the job fails; mirror that here — otherwise Mail
    # swallows the error and there is nothing for the retry layer to catch.
    ActionMailer::Base.raise_delivery_errors = true
    FlakyRelay.attempts = 0
    FlakyRelay.failures = 0
  end

  teardown do
    ActionMailer::Base.delivery_method = @original_delivery_method
    ActionMailer::Base.raise_delivery_errors = @original_raise_delivery
  end

  test "a transient SMTP failure is retried until the alert actually goes out" do
    FlakyRelay.failures = 2

    perform_enqueued_jobs do
      MonitorMailer.down(monitors(:up)).deliver_later
    end

    assert_equal 3, FlakyRelay.attempts, "expected two transient failures to be retried, then delivered"
  end

  test "retries are bounded — a permanently broken relay fails the job loudly" do
    FlakyRelay.failures = Float::INFINITY

    # perform_enqueued_jobs' block form asserts nothing was raised, and here the
    # exhausted job MUST raise (so Solid Queue records a failed job), so drive the
    # test adapter directly instead.
    assert_raises(Net::SMTPServerBusy) do
      performing_jobs_inline { MonitorMailer.down(monitors(:up)).deliver_later }
    end

    assert_equal 5, FlakyRelay.attempts, "expected a bounded 5 attempts, then a failed job"
  end

  private
    def performing_jobs_inline
      adapter = queue_adapter
      previous = [ adapter.perform_enqueued_jobs, adapter.perform_enqueued_at_jobs ]
      adapter.perform_enqueued_jobs = true
      adapter.perform_enqueued_at_jobs = true
      yield
    ensure
      adapter.perform_enqueued_jobs, adapter.perform_enqueued_at_jobs = previous
    end
end
