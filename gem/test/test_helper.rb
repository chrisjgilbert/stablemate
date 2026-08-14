# frozen_string_literal: true

require "minitest/autorun"
require "stablemate"

module Stablemate
  # Collects the warnings a component logs, so tests can assert on them without
  # parsing a StringIO. The logger is pluggable public API, so a plain object
  # answering #warn is all the contract requires.
  #
  # Warnings arrive from the subscriber's background dispatcher threads as well
  # as inline, hence the mutex on the snapshot and the Queue behind
  # #next_warning — a cross-thread test that polled an Array would be flaky.
  class RecordingLogger
    def initialize
      @lock = Mutex.new
      @warnings = []
      @errors = []
      @arrivals = Queue.new
    end

    def warn(message)
      @lock.synchronize { @warnings << message }
      @arrivals << message
    end

    # §6.5 routes the four check-in states' copy through error level, so the
    # double has to answer #error as well as #warn. Deliberately NOT pushed onto
    # @arrivals: #next_warning is a blocking read for a specific warning, and an
    # error line arriving first would satisfy the pop and fail the assertion.
    def error(message)
      @lock.synchronize { @errors << message }
    end

    # A snapshot, safe to read while background threads are still logging.
    def warnings = @lock.synchronize { @warnings.dup }

    def errors = @lock.synchronize { @errors.dup }

    # Blocks until the next warning lands, so a cross-thread test is
    # deterministic rather than timed.
    def next_warning(timeout: 5)
      require "timeout"
      Timeout.timeout(timeout) { @arrivals.pop }
    end
  end

  # A logger whose #warn raises. The pluggable logger is public API, so a broken
  # sink (closed IO, full disk) must not let anything escape into the host job —
  # this is the only thing this double is for.
  class RaisingLogger
    def initialize(error) = @error = error

    def warn(_message) = raise(@error)

    def error(_message) = raise(@error)
  end

  # A fake client capturing sync payloads and check-ins — the gem's tests must
  # make NO real network calls (CLAUDE.md environment rule).
  class FakeClient
    attr_reader :synced, :pinged, :reported, :ping_threads

    # sync_response: the parsed hash sync_monitors should return.
    # ping_error: raise this from #ping / #report_failure to exercise the
    #   swallow-everything path.
    def initialize(sync_response: { "monitors" => [], "skipped" => [] }, ping_error: nil)
      @sync_response = sync_response
      @ping_error = ping_error
      @synced = []
      @pinged = []
      @reported = []
      # Which thread each check-in arrived on — the default dispatcher is supposed
      # to get them off the caller's thread, and that is only observable from in
      # here. A Queue rather than an Array so a test can block until a check-in
      # lands instead of polling for it. Pushed LAST in #ping (see there).
      @ping_threads = Queue.new
      # check-ins arrive from the subscriber's background threads, so the sink must
      # be thread-safe for the concurrency test.
      @lock = Mutex.new
    end

    # declared_keys / prune ride along only on a PRUNE=1 run (§6.1), so they are
    # recorded rather than defaulted away: "a non-prune run sends neither" is an
    # assertion the suite has to be able to make.
    def sync_monitors(app:, monitors:, declared_keys: nil, prune: false)
      @synced << { app:, monitors:, declared_keys:, prune: }
      @sync_response
    end

    # Takes the TASK KEY, like the real Client — there is no URL to resolve any
    # more, which is why this double records keys.
    def ping(registration_key)
      raise @ping_error if @ping_error

      @lock.synchronize { @pinged << registration_key }
      # LAST, and after the @pinged append: a test that blocks on ping_threads.pop
      # is released by this push, so anything it then asserts about @pinged must
      # already be recorded. Pushing first leaves a window in which the popping
      # thread runs before the background thread appends the key.
      @ping_threads << Thread.current
      :ok
    end

    # Mirrors the real Client#report_failure contract (same argument, same
    # error-injection knob) and records the key + message for assertions.
    def report_failure(registration_key, message:)
      raise @ping_error if @ping_error

      @lock.synchronize { @reported << { key: registration_key, message: message } }
      :ok
    end
  end
end

class StablemateTest < Minitest::Test
  # Runs a dispatched ping block synchronously, so by the time handle_event
  # returns the ping has already hit the fake client — deterministic.
  SYNC_DISPATCHER = ->(blk) { blk.call }

  def setup
    Stablemate.reset!
  end

  def teardown
    Stablemate.reset!
  end

  # Path to a fixture recurring.yml.
  def fixture(name)
    File.expand_path("fixtures/#{name}", __dir__)
  end

  # A config whose logger writes to the given StringIO, for log assertions.
  def logging_config(out)
    config = Stablemate::Configuration.new
    config.logger = Logger.new(out)
    config
  end
end
