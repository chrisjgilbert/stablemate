class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private
    # Iterate a sweep's scope, skipping records that disappear underneath it.
    #
    # A sweep queries its batch and then works through it one record at a time, so
    # any row can be deleted between the query and its turn. The record methods
    # sweeps call re-read under a lock (`with_lock` is `reload(lock: true)`), which
    # raises RecordNotFound on a vanished row — and one raise aborts the whole run,
    # leaving every record after it unprocessed. In the detection sweep that means a
    # genuine outage goes unalerted because someone else closed their account in the
    # same 30 seconds.
    #
    # Closing an account cascades away all of a user's monitors at once
    # (User::Closure), which makes this ordinary rather than exotic. Handling it in
    # the iteration keeps the record methods' contracts honest — they still raise if
    # asked to act on something that no longer exists — and gives every sweep the
    # same guarantee instead of each one rediscovering it.
    def each_record(scope)
      scope.find_each do |record|
        yield record
      rescue ActiveRecord::RecordNotFound
        next
      end
    end
end
