# frozen_string_literal: true

require_relative "test_helper"

# §6.5 — the gem's log lines are the ONLY signal a misconfigured deploy produces
# now that boot no longer syncs, so they must land in the host's log rather than
# on the stderr channel the original boot-sync warning went to unseen.
class LoggingTest < StablemateTest
  def test_logger_prefers_rails_logger_when_rails_is_defined
    sink = Stablemate::RecordingLogger.new

    with_fake_rails(sink) do
      assert_same sink, Stablemate.logger
    end
  end

  # An explicitly configured logger is still the most specific answer.
  def test_an_explicit_config_logger_wins_over_rails
    sink = Stablemate::RecordingLogger.new
    configured = Stablemate::RecordingLogger.new
    Stablemate.config.logger = configured

    with_fake_rails(sink) do
      assert_same configured, Stablemate.logger
    end
  end

  # Rails.logger is nil until the logger initializer has run — a boot-time call
  # must fall through, not return nil and NoMethodError on .error.
  def test_a_nil_rails_logger_falls_back_to_the_default
    with_fake_rails(nil) do
      assert_respond_to Stablemate.logger, :error
    end
  end

  def test_without_rails_the_default_logger_still_answers
    refute defined?(::Rails), "a fake Rails leaked out of another test"
    assert_respond_to Stablemate.logger, :error
  end

  # §6.5 needs error level with the [stablemate] prefix. Stablemate.log_error can
  # never exist — Stablemate's singleton does not include Logging — so the helper
  # is for objects that include the module, and the railtie calls
  # Stablemate.logger.error directly.
  def test_log_error_prefixes_and_routes_to_the_configured_logger
    sink = Stablemate::RecordingLogger.new
    config = Stablemate::Configuration.new
    config.logger = sink

    Loggable.new(config).boom("check-in rejected 401")

    assert_equal [ "[stablemate] check-in rejected 401" ], sink.errors
  end

  # The logger is pluggable public API and these helpers are called from
  # last-line-of-defence rescues: a raising sink must not become the thing that
  # propagates into the host job.
  def test_log_error_swallows_a_raising_logger
    config = Stablemate::Configuration.new
    config.logger = Stablemate::RaisingLogger.new(IOError.new("closed"))

    assert_nil Loggable.new(config).boom("nope")
  end

  class Loggable
    include Stablemate::Logging

    def initialize(config) = @config = config

    def boom(message) = log_error(message)

    private
      attr_reader :config
  end

  private
    # Defines a stand-in ::Rails for the duration of the block. It deliberately
    # does NOT answer #env, so Configuration#default_environment keeps resolving
    # from the environment variables.
    #
    # Refuses to run if something already defined ::Rails rather than removing a
    # constant it did not create: the gem suite runs without Rails, and an ensure
    # that unconditionally removed it would corrupt the process for every test
    # after it.
    def with_fake_rails(sink)
      raise "::Rails is already defined — this helper would clobber it" if Object.const_defined?(:Rails)

      fake = Module.new do
        define_singleton_method(:logger) { sink }
      end
      Object.const_set(:Rails, fake)
      yield
    ensure
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails) && Object.const_get(:Rails).equal?(fake)
    end
end
