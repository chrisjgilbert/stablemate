# frozen_string_literal: true

require "minitest/autorun"
require "stablemate"

module Stablemate
  # A fake client capturing sync payloads and pings — the gem's tests must make
  # NO real network calls (CLAUDE.md environment rule).
  class FakeClient
    attr_reader :synced, :pinged

    # sync_response: the parsed hash sync_monitors should return.
    # ping_error: raise this from #ping to exercise the swallow-everything path.
    def initialize(sync_response: { "monitors" => [], "skipped" => [] }, ping_error: nil)
      @sync_response = sync_response
      @ping_error = ping_error
      @synced = []
      @pinged = []
      # pings arrive from the subscriber's background threads, so the sink must be
      # thread-safe for the concurrency test.
      @lock = Mutex.new
    end

    def sync_monitors(app:, monitors:)
      @synced << { app:, monitors: }
      @sync_response
    end

    def ping(ping_url)
      raise @ping_error if @ping_error

      @lock.synchronize { @pinged << ping_url }
      true
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
