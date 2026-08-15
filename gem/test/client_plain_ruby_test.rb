# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tempfile"

# §12 "Gem on a plain-Ruby host": a check-in with a space in the task name must
# succeed with Rails NOT loaded — which fails if client.rb does not require "erb".
#
# This has to run in a SUBPROCESS. In-process the test would pass on any process
# where something else has already required erb, and the failure it guards is
# invisible by construction: ERB::Util without the require raises NameError,
# NameError is a StandardError, #ping's own rescue swallows it, and §6.5
# classifies the result as transient — every check-in dropped with no 401 or 404
# logged, and the monitor goes down claiming it missed its check-in.
class ClientPlainRubyTest < StablemateTest
  SCRIPT = <<~RUBY
    # The whole point of the subprocess: prove erb is not already loaded BEFORE
    # the gem gets a chance to require it.
    abort("erb was preloaded — this run proves nothing") if defined?(ERB)

    require "stablemate"

    abort("Rails is loaded — this run proves nothing") if defined?(Rails)

    class Recorder
      def initialize(captured) = @captured = captured
      def post(path, _body, _headers = nil)
        @captured[:path] = path
        Net::HTTPOK.new("1.1", "200", "OK")
      end
    end

    captured = {}
    config = Stablemate::Configuration.new
    config.endpoint = "https://sm.test"
    config.ping_key = "sm_ping_plainruby"

    client = Stablemate::Client.new(config, http_factory: ->(_uri) { Recorder.new(captured) })
    status = client.ping("my task")

    puts captured[:path].inspect
    puts status.inspect
  RUBY

  def test_a_check_in_with_a_space_lands_on_a_plain_ruby_host
    out, status = run_script(SCRIPT)

    assert status.success?, "subprocess failed: #{out}"
    assert_equal [ '"/api/v1/monitors/my%20task/pings"', ":ok" ], out.split("\n")
  end

  private
    # A file rather than `ruby -e`: a -e script is read in the LOCALE encoding, so
    # the non-ASCII characters in these comments would be a syntax error under a
    # C locale, while a source file is UTF-8 regardless.
    def run_script(source)
      Tempfile.create([ "stablemate_plain_ruby", ".rb" ]) do |file|
        file.write(source)
        file.flush
        Open3.capture2e(RbConfig.ruby, "-I", lib_path, file.path)
      end
    end

    def lib_path = File.expand_path("../lib", __dir__)
end
