# frozen_string_literal: true

require_relative "../test_helper"
require "active_job"
require "active_support/test_case"

# Loading activejob attaches its LogSubscriber to perform.active_job globally;
# subscriber_test.rb instruments that event with a minimal fake job (no job_id),
# which would make the log subscriber spew "Could not log" noise into the run.
# Nothing in this suite asserts on ActiveJob's own logging — detach it.
ActiveJob::LogSubscriber.detach_from :active_job if defined?(ActiveJob::LogSubscriber)

# Smoke test for the after_discard wiring (spec §3.2 / §11 [gem]) on the REAL
# ActiveJob test adapter: Subscriber#subscribe_discards! registers one global
# ActiveJob::Base.after_discard callback (the same call the railtie makes), and
# a TERMINAL failure — and only a terminal failure — produces exactly one
# failure report:
#   - unhandled raise (no retry_on/discard_on)  -> one report
#   - retry_on succeeding on a later attempt    -> ZERO reports
#   - retry_on exhausted                        -> one report
#   - discard_on                                -> one report
class AfterDiscardWiringTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  Boom = Class.new(StandardError)
  Flaky = Class.new(StandardError)

  class NoHandlerJob < ActiveJob::Base
    def perform = raise Boom, "no handler"
  end

  class RecoversJob < ActiveJob::Base
    retry_on Flaky, wait: 1, attempts: 2
    cattr_accessor :runs, default: 0
    def perform
      self.runs += 1
      raise Flaky, "first attempt" if runs == 1
    end
  end

  class ExhaustsJob < ActiveJob::Base
    retry_on Boom, wait: 1, attempts: 2
    def perform = raise Boom, "always fails"
  end

  class DiscardsJob < ActiveJob::Base
    discard_on Boom
    def perform = raise Boom, "discarded"
  end

  ALL_JOBS = [ NoHandlerJob, RecoversJob, ExhaustsJob, DiscardsJob ].freeze

  def setup
    Stablemate.reset!
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    # after_discard registration is additive class state on ActiveJob::Base —
    # snapshot and restore it so each test sees exactly one wired callback.
    @saved_procs = ActiveJob::Base.after_discard_procs
    @client = Stablemate::FakeClient.new
    Stablemate::Execution::Subscriber.new(
      class_to_keys: ALL_JOBS.to_h { |job| [ job.name, [ "task_#{job.name.demodulize.underscore}" ] ] },
      ping_urls: ALL_JOBS.to_h { |job| [ "task_#{job.name.demodulize.underscore}", "https://sm.test/ping/#{job.name.demodulize.underscore}" ] },
      client: @client, config: Stablemate.config, dispatcher: StablemateTest::SYNC_DISPATCHER
    ).subscribe_discards!
  end

  def teardown
    ActiveJob::Base.after_discard_procs = @saved_procs
    Stablemate.reset!
  end

  # perform_enqueued_jobs internally wraps execution in assert_nothing_raised,
  # so a terminal raise that (correctly) escapes the job surfaces as a Minitest
  # error — swallow anything; the behaviour under test is the report count.
  def drain_swallowing_terminal_raise(&blk)
    perform_enqueued_jobs(&blk)
  rescue Exception # rubocop:disable Lint/RescueException
    nil
  end

  def test_unhandled_raise_reports_exactly_one_failure
    drain_swallowing_terminal_raise { NoHandlerJob.perform_later }

    assert_equal 1, @client.reported.size
    report = @client.reported.first
    assert_equal "https://sm.test/ping/no_handler_job", report[:url]
    assert_equal "AfterDiscardWiringTest::Boom: no handler", report[:message]
  end

  def test_retry_on_recovering_on_attempt_two_reports_nothing
    RecoversJob.runs = 0

    perform_enqueued_jobs { RecoversJob.perform_later }

    assert_equal 2, RecoversJob.runs, "expected the job to run twice (one retry)"
    assert_empty @client.reported
  end

  def test_retry_on_exhausted_reports_exactly_one_failure
    drain_swallowing_terminal_raise { ExhaustsJob.perform_later }

    assert_equal 1, @client.reported.size
    assert_equal "AfterDiscardWiringTest::Boom: always fails", @client.reported.first[:message]
  end

  def test_discard_on_reports_exactly_one_failure
    perform_enqueued_jobs { DiscardsJob.perform_later }

    assert_equal 1, @client.reported.size
    assert_equal "AfterDiscardWiringTest::Boom: discarded", @client.reported.first[:message]
  end

  # The wired callback runs inside ActiveJob's run_after_discard_procs, which
  # RE-RAISES callback exceptions into the host worker — a raising client must
  # not turn a discarded job into a crashed worker.
  def test_a_raising_client_never_escapes_into_the_host_via_after_discard
    ActiveJob::Base.after_discard_procs = @saved_procs
    raising_client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    Stablemate::Execution::Subscriber.new(
      class_to_keys: { "AfterDiscardWiringTest::DiscardsJob" => [ "k" ] },
      ping_urls: { "k" => "https://sm.test/ping/x" },
      client: raising_client, config: Stablemate.config, dispatcher: StablemateTest::SYNC_DISPATCHER
    ).subscribe_discards!

    perform_enqueued_jobs { DiscardsJob.perform_later }

    assert_empty raising_client.reported
  end
end
