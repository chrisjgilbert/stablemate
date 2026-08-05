require "test_helper"

# [job] ApplicationJob#each_record — the guarantee every sweep inherits: one
# record vanishing mid-run must not abandon the rest of the batch.
#
# Tested here rather than in each sweep's own test because that is where the
# behaviour lives (ApplicationJob's comment: "gives every sweep the same
# guarantee instead of each one rediscovering it"). Each sweep's own test still
# pins that it goes THROUGH here — see detect_missed_pings_job_test.rb.
#
# No test double is needed: a LOADED relation is what a sweep actually holds, and
# `find_each` on one iterates the records already in memory (Batches
# #batch_on_loaded_relation) rather than re-querying — so a row deleted
# underneath it is still yielded, which is exactly the situation the rescue
# exists for.
class ApplicationJobTest < ActiveJob::TestCase
  # A sweep whose per-record work is supplied by the test, so the iteration is
  # what is under test rather than any one sweep's domain logic.
  class SweepJob < ApplicationJob
    def perform(batch, work) = each_record(batch) { |record| work.call(record) }
  end

  setup do
    Monitoring::Monitor.delete_all
    @project = users(:alice).projects.sole
  end

  test "a record deleted after the batch was loaded is skipped, and the rest still run" do
    ghost = overdue_monitor("ghost")
    survivor = overdue_monitor("survivor")
    batch = loaded_batch(ghost, survivor) # the batch as the sweep queried it…
    Monitoring::Monitor.where(id: ghost.id).delete_all # …and the account closed mid-sweep

    assert_nothing_raised { SweepJob.perform_now(batch, :flag_missed!.to_proc) }

    assert survivor.reload.down?, "the sweep must carry on past a record that vanished"
  end

  # The rescue is deliberately narrow: RecordNotFound means "this one is gone",
  # and swallowing anything wider would turn a real bug into a silent no-op
  # across every sweep in the app.
  test "any other error still stops the sweep rather than being swallowed" do
    batch = loaded_batch(overdue_monitor("boom"))

    assert_raises(ZeroDivisionError) do
      SweepJob.perform_now(batch, ->(_) { 1 / 0 })
    end
  end

  private
    def overdue_monitor(name)
      @project.monitors.create!(
        name: name, expected_interval_seconds: 3600, grace_period_seconds: 300,
        status: "up", last_ping_at: 3.days.ago, next_due_at: 3.days.ago
      )
    end

    # Loaded up front, so #find_each walks these very records — including any the
    # database no longer has. It yields them in id order (batching orders by the
    # cursor), which is creation order here, so the ghost is walked first.
    def loaded_batch(*monitors)
      Monitoring::Monitor.where(id: monitors.map(&:id)).load
    end
end
