class ApplicationJob < ActiveJob::Base
  private
    # Iterate a sweep's scope, skipping records that disappear underneath it.
    #
    # A sweep queries its batch and then works through it one record at a time, so
    # any row can be deleted between the query and its turn. The record methods
    # sweeps call re-read under a lock, which raises RecordNotFound on a vanished
    # row — and one raise aborts the whole run, leaving every record after it
    # unprocessed. Closing an account cascades away all of a user's monitors at
    # once, which makes this ordinary rather than exotic.
    def each_record(scope)
      scope.find_each do |record|
        yield record
      rescue ActiveRecord::RecordNotFound
        next
      end
    end
end
