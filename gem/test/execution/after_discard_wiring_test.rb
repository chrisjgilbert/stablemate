# frozen_string_literal: true

require_relative "../test_helper"
require "active_job"
require "active_support/test_case"

# Loading activejob attaches its log subscribers to perform.active_job
# globally; subscriber_test.rb instruments that event with a minimal fake job,
# which would make them spew "Could not log" noise into the run. Nothing in
# this suite asserts on ActiveJob's own logging — detach them. Both constants
# are autoloaded and attach at load, so resolve them (which loads + attaches)
# BEFORE detaching. (This lives here because this file is the suite's only
# require-site of activejob: without it the subscribers never attach at all.)
ActiveJob::Base # force-load so all lazy attach_to calls have happened
%w[ActiveJob::LogSubscriber ActiveJob::StructuredEventSubscriber].each do |name|
  subscriber = begin
    Object.const_get(name)
  rescue NameError
    nil
  end
  subscriber&.detach_from :active_job
end

# Smoke test for the terminal-failure wiring (spec §3.2 / §11 [gem]) on the
# REAL ActiveJob adapter, with BOTH paths attached exactly as the railtie
# attaches them (subscribe! + subscribe_discards! — the success subscription
# must be present, because the perform.active_job payload records only
# UNHANDLED exceptions: a discard_on/retry_on-handled failure closes its
# perform event with a clean payload, and only the failed-attempt marker keeps
# it from success-pinging). Pinned per scenario — failure reports AND success
# pings:
#   - unhandled raise (no retry_on/discard_on)  -> 1 report, 0 pings
#   - a will-retry attempt                      -> 0 reports, 0 pings
#   - retry_on succeeding on a later attempt    -> 0 reports, 1 ping (the success)
#   - retry_on exhausted                        -> 1 report, 0 pings
#   - discard_on                                -> 1 report, 0 pings
#   - clean success                             -> 0 reports, 1 ping
#
# Deviation from spec §11's "inline adapter" wording (deliberate, per
# CLAUDE.md's say-so rule): the TEST adapter is used instead, because the
# inline adapter cannot schedule retry_on's delayed re-enqueue (its enqueue_at
# raises NotImplementedError), so none of the retry scenarios would run.
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

  class WillRetryJob < ActiveJob::Base
    retry_on Flaky, wait: 1, attempts: 3
    def perform = raise Flaky, "will retry"
  end

  class ExhaustsJob < ActiveJob::Base
    retry_on Boom, wait: 1, attempts: 2
    def perform = raise Boom, "always fails"
  end

  class DiscardsJob < ActiveJob::Base
    discard_on Boom
    def perform = raise Boom, "discarded"
  end

  class SucceedsJob < ActiveJob::Base
    def perform = :ok
  end

  # For the copy-on-write shadowing test: the parent registers its OWN
  # after_discard inside the test body (i.e. after the gem hook is installed,
  # mirroring production boot order where the railtie initializer runs before
  # app job classes load).
  class TrackedParentJob < ActiveJob::Base; end
  class TrackedChildJob < TrackedParentJob
    discard_on Boom
    def perform = raise Boom, "tracked"
  end

  ALL_JOBS = [ NoHandlerJob, RecoversJob, WillRetryJob, ExhaustsJob, DiscardsJob, SucceedsJob,
               TrackedChildJob ].freeze

  def key_for(job_class) = "task_#{job_class.name.demodulize.underscore}"
  def url_for(job_class) = "https://sm.test/ping/#{job_class.name.demodulize.underscore}"

  def build_subscriber(client)
    Stablemate::Execution::Subscriber.new(
      class_to_keys: ALL_JOBS.to_h { |job| [ job.name, [ key_for(job) ] ] },
      ping_urls: ALL_JOBS.to_h { |job| [ key_for(job), url_for(job) ] },
      client:, config: Stablemate.config, dispatcher: StablemateTest::SYNC_DISPATCHER
    )
  end

  # The full production wiring (what the railtie does): success subscription +
  # armed as the global discard reporter.
  def wire_subscriber(client)
    build_subscriber(client).subscribe!.subscribe_discards!
  end

  # Discard path only, for the re-arm tests — a second perform.active_job
  # subscription would just double-listen on the success side; each test wires
  # exactly what it exercises.
  def arm_discards_only(client)
    build_subscriber(client).subscribe_discards!
  end

  def setup
    Stablemate.reset!
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    @client = Stablemate::FakeClient.new
    @subscriber = wire_subscriber(@client)
  end

  def teardown
    @subscriber.unsubscribe!
    Stablemate.reset!
  end

  # perform_enqueued_jobs internally wraps execution in assert_nothing_raised,
  # so a terminal raise that (correctly) escapes the job surfaces as a Minitest
  # error — swallow anything; the behaviour under test is the report/ping count.
  def drain_swallowing_terminal_raise(&blk)
    perform_enqueued_jobs(&blk)
  rescue Exception # rubocop:disable Lint/RescueException
    nil
  end

  def test_unhandled_raise_reports_exactly_once_and_never_success_pings
    drain_swallowing_terminal_raise { NoHandlerJob.perform_later }

    assert_equal 1, @client.reported.size
    report = @client.reported.first
    assert_equal "https://sm.test/ping/no_handler_job", report[:url]
    assert_equal "AfterDiscardWiringTest::Boom: no handler", report[:message]
    assert_empty @client.pinged
  end

  # The clock-reset half of the marker bug: a failed attempt that WILL be
  # retried must send nothing at all — a bare success ping here would advance
  # the monitor's overdue clock on the strength of a failure.
  def test_a_will_retry_attempt_reports_nothing_and_pings_nothing
    WillRetryJob.perform_now # attempt 1: retry_on catches and re-enqueues

    assert_empty @client.reported
    assert_empty @client.pinged
  end

  def test_retry_on_recovering_on_attempt_two_reports_nothing_and_pings_the_success
    RecoversJob.runs = 0

    perform_enqueued_jobs { RecoversJob.perform_later }

    assert_equal 2, RecoversJob.runs, "expected the job to run twice (one retry)"
    assert_empty @client.reported
    assert_equal [ url_for(RecoversJob) ], @client.pinged, "only the successful attempt may ping"
  end

  def test_retry_on_exhausted_reports_exactly_once_and_never_success_pings
    drain_swallowing_terminal_raise { ExhaustsJob.perform_later }

    assert_equal 1, @client.reported.size
    assert_equal "AfterDiscardWiringTest::Boom: always fails", @client.reported.first[:message]
    assert_empty @client.pinged
  end

  # The double-fire half of the marker bug: a discard_on failure leaves the
  # perform payload exception-free, so without the marker it would BOTH report
  # a failure AND success-ping (flapping the monitor down->up with a spurious
  # recovered email).
  def test_discard_on_reports_exactly_once_and_never_success_pings
    perform_enqueued_jobs { DiscardsJob.perform_later }

    assert_equal 1, @client.reported.size
    assert_equal "AfterDiscardWiringTest::Boom: discarded", @client.reported.first[:message]
    assert_empty @client.pinged
  end

  def test_a_clean_success_pings_and_reports_nothing
    perform_enqueued_jobs { SucceedsJob.perform_later }

    assert_empty @client.reported
    assert_equal [ url_for(SucceedsJob) ], @client.pinged
  end

  # The wired callback runs inside ActiveJob's run_after_discard_procs, which
  # RE-RAISES callback exceptions into the host worker — a raising client must
  # not turn a discarded job into a crashed worker.
  def test_a_raising_client_never_escapes_into_the_host_via_after_discard
    raising_client = Stablemate::FakeClient.new(ping_error: SocketError.new("no network"))
    # Re-arm with a second subscriber: the delegating Base hook now routes
    # discards to this one (never stacking a second callback).
    sub = arm_discards_only(raising_client)

    perform_enqueued_jobs { DiscardsJob.perform_later }

    assert_empty raising_client.reported
  ensure
    sub&.unsubscribe!
  end

  # Re-wiring replaces the armed subscriber — the Base-level hook is installed
  # once and DELEGATES to the currently-armed one, so a detach/re-wire cycle
  # can never stack callbacks and double-report.
  def test_rewiring_does_not_stack_discard_callbacks
    replacement_client = Stablemate::FakeClient.new
    sub = arm_discards_only(replacement_client)

    perform_enqueued_jobs { DiscardsJob.perform_later }

    assert_equal 1, replacement_client.reported.size, "re-wiring must not double-report"
    assert_empty @client.reported, "a replaced subscriber must no longer receive discards"
  ensure
    sub&.unsubscribe!
  end

  # after_discard_procs is a COPY-ON-WRITE class_attribute: a job class that
  # registers its own after_discard snapshots Base's array at that moment.
  # Because the gem hook is installed BEFORE app job classes register theirs
  # (railtie initializer + on_load(:active_job), mirrored here by setup running
  # before this test body), the parent's copy already contains our hook — its
  # own callback must not shed the gem's failure reporting for its subtree.
  def test_a_job_class_registering_its_own_after_discard_keeps_gem_reporting
    parent_fired = []
    TrackedParentJob.after_discard { |_job, _exception| parent_fired << true }

    perform_enqueued_jobs { TrackedChildJob.perform_later }

    assert_equal 1, parent_fired.size, "the host's own callback must fire"
    assert_equal 1, @client.reported.size, "the gem hook must fire despite the parent-level copy"
    assert_equal "AfterDiscardWiringTest::Boom: tracked", @client.reported.first[:message]
  ensure
    # Drop the parent-level shadow so repeated registrations can't pile up
    # if more tests ever touch this hierarchy.
    TrackedParentJob.after_discard_procs = ActiveJob::Base.after_discard_procs
  end

  # remove_discard_hook is the teardown counterpart of install_discard_hook:
  # after it, discards reach nobody even while a subscriber is still armed.
  def test_remove_discard_hook_disconnects_reporting
    Stablemate::Execution::Subscriber.remove_discard_hook

    perform_enqueued_jobs { DiscardsJob.perform_later }

    assert_empty @client.reported
  ensure
    # Reinstall for the rest of the suite (setup arms; install is idempotent).
    Stablemate::Execution::Subscriber.install_discard_hook
  end
end
