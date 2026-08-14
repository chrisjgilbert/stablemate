# frozen_string_literal: true

require_relative "../test_helper"
require "rake"

# The install task has the same single decision the sync task does, and the same
# reason to pin it at the real entry point: an install whose credentials did not
# verify has proved nothing, and exiting 0 there is the difference between
# finding out now and finding out when a job silently stops being monitored
# (§6.6).
class InstallRakeTaskTest < StablemateTest
  TASK_FILE = File.expand_path("../../lib/stablemate/tasks/stablemate.rake", __dir__)

  def setup
    super
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
    # The task's :environment prerequisite is Rails'; stub it, because what is
    # under test is the exit status and not booting an app.
    Rake::Task.define_task(:environment)
    load TASK_FILE
  end

  def teardown
    Rake.application = @previous_application
    super
  end

  def task = Rake::Task["stablemate:install"]

  # Hand-rolled rather than Minitest::Mock#stub: minitest 6 moved the mock half
  # into a separate gem this gemspec does not depend on, and the alternative —
  # letting the real command run — would put a network call in the suite.
  def with_command_answering(answer)
    calls = []
    command = Object.new
    command.define_singleton_method(:install!) do
      calls << :install!
      answer
    end
    Stablemate::Commands::Install.define_singleton_method(:new) { |**| command }
    yield calls
  ensure
    Stablemate::Commands::Install.singleton_class.send(:remove_method, :new)
  end

  def test_a_failed_install_exits_non_zero
    with_command_answering(false) do
      error = assert_raises(SystemExit) { task.invoke }

      assert_equal 1, error.status
    end
  end

  def test_a_successful_install_exits_zero
    with_command_answering(true) do |calls|
      task.invoke # no SystemExit: rake exits 0 of its own accord

      assert_equal [ :install! ], calls
    end
  end

  # The keys ride in as `NAME=VALUE` rake arguments — already in ENV by the time
  # the task body runs, under the same names the initializer skeleton reads. A
  # task with declared arguments would have to be invoked as
  # `stablemate:install[key,key]`, which is not the line §7's setup panel renders.
  def test_the_task_takes_no_arguments
    assert_empty task.arg_names
  end
end
