# frozen_string_literal: true

require_relative "../test_helper"
require "rake"

# The rake file has exactly one decision left in it, and it is the one §6.1
# calls the entire evidence a deploy has: a false answer from the command must
# FAIL THE DEPLOY. Every register-nothing path used to exit 0 — two of them
# without making a request at all — so this is worth pinning at the real entry
# point and not only at the object behind it.
class SyncRakeTaskTest < StablemateTest
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

  def task
    Rake::Task["stablemate:sync"]
  end

  # Hand-rolled rather than Minitest::Mock#stub: minitest 6 moved the mock half
  # into a separate gem this gemspec does not depend on, and the alternative —
  # letting the real command run — would put a network call in the suite.
  def with_command_answering(answer)
    calls = []
    command = Object.new
    command.define_singleton_method(:sync!) do
      calls << :sync!
      answer
    end
    Stablemate::Commands::Sync.define_singleton_method(:new) { |**| command }
    yield calls
  ensure
    Stablemate::Commands::Sync.singleton_class.send(:remove_method, :new)
  end

  def test_a_failed_run_exits_non_zero
    with_command_answering(false) do
      error = assert_raises(SystemExit) { task.invoke }

      assert_equal 1, error.status
    end
  end

  def test_a_successful_run_exits_zero
    with_command_answering(true) do |calls|
      task.invoke # no SystemExit: rake exits 0 of its own accord

      assert_equal [ :sync! ], calls
    end
  end

  # PRUNE=1 and FORCE=1 are read from the environment by the command, so the
  # task takes no arguments at all — a rake task with arguments would have to be
  # invoked as `stablemate:sync[1]`, which no deploy hook is going to write.
  def test_the_task_takes_no_arguments
    assert_empty task.arg_names
  end
end
