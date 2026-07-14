# frozen_string_literal: true

require "minitest/autorun"
require "stablemate"

module Stablemate
  # A fake client capturing sync payloads and pings — the gem's tests must make
  # NO real network calls (CLAUDE.md environment rule).
  class FakeClient
    attr_reader :synced, :pinged, :listed

    # sync_response: the parsed hash sync_monitors should return.
    # list_response: the parsed hash list_monitors should return (register_on_boot
    #   = false path).
    # ping_error: raise this from #ping to exercise the swallow-everything path.
    def initialize(sync_response: { "monitors" => [], "skipped" => [] }, list_response: { "monitors" => [] },
                   ping_error: nil, ping_status: :ok)
      @sync_response = sync_response
      @list_response = list_response
      @ping_error = ping_error
      @ping_status = ping_status
      @synced = []
      @listed = 0
      @pinged = []
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
      raise @ping_error if @ping_error

      @lock.synchronize { @pinged << ping_url }
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
