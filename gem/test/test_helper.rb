# frozen_string_literal: true

require "minitest/autorun"
require "stablemate"

module Stablemate
  # A fake client capturing sync payloads and pings — the gem's tests must make
  # NO real network calls (CLAUDE.md environment rule).
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
      @arrivals = Queue.new
    end

    def warn(message)
      @lock.synchronize { @warnings << message }
      @arrivals << message
    end

    # A snapshot, safe to read while background threads are still logging.
    def warnings = @lock.synchronize { @warnings.dup }

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
  end

  class FakeClient
    attr_reader :synced, :pinged, :listed, :reported, :ping_threads

    # sync_response: the parsed hash sync_monitors should return.
    # list_response: the parsed hash list_monitors should return (register_on_boot
    #   = false path).
    # ping_error: raise this from #ping / #report_failure to exercise the
    #   swallow-everything path.
    def initialize(sync_response: { "monitors" => [], "skipped" => [] }, list_response: { "monitors" => [] },
                   ping_error: nil, ping_status: :ok)
      @sync_response = sync_response
      @list_response = list_response
      @ping_error = ping_error
      @ping_status = ping_status
      @synced = []
      @listed = 0
      @pinged = []
      @reported = []
      # Which thread each ping arrived on — the default dispatcher is supposed to
      # get them off the caller's thread, and that is only observable from in here.
      # A Queue rather than an Array so a test can block until a ping lands
      # instead of polling for it.
      @ping_threads = Queue.new
      # pings arrive from the subscriber's background threads, so the sink must be
      # thread-safe for the concurrency test.
      @lock = Mutex.new
    end

    def sync_monitors(app:, monitors:)
      @synced << { app:, monitors: }
      @sync_response
    end

    def list_monitors
      @listed += 1
      @list_response
    end

    # Returns the configured ping status (:ok / :stale / :error), matching the real
    # Client's contract so the subscriber's re-sync path can be exercised.
    def ping(ping_url)
      @ping_threads << Thread.current
      raise @ping_error if @ping_error

      @lock.synchronize { @pinged << ping_url }
      @ping_status
    end

    # Mirrors the real Client#report_failure contract (same statuses, same
    # error-injection knob) and records the url + message for assertions.
    def report_failure(ping_url, message:)
      raise @ping_error if @ping_error

      @lock.synchronize { @reported << { url: ping_url, message: message } }
      @ping_status
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
