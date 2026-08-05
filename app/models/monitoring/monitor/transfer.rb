module Monitoring
  class Monitor
    # Move a monitor into another of the user's projects, reached via
    # monitor.transfer_to(project). Manual-only: a gem monitor belongs to whichever
    # project its API key syncs into, so moving it here would just be undone on the
    # next sync.
    #
    # Tenant/cross-project scoping is the controller's job (it resolves the target
    # through current_user.projects).
    class Transfer
      Result = Struct.new(:ok?, :error)

      def initialize(monitor)
        @monitor = monitor
      end

      def transfer_to(project)
        return Result.new(false, :not_manual) unless @monitor.manual?
        return Result.new(true, nil) if @monitor.project_id == project.id

        @monitor.update!(project: project)
        Result.new(true, nil)
      rescue ActiveRecord::RecordNotUnique
        # The target already holds a monitor with this registration_key.
        Result.new(false, :collision)
      end
    end
  end
end
