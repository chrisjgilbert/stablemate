module Monitoring
  class Monitor
    # Operation (CLAUDE.md §4): move a monitor into another of the user's projects,
    # reached via monitor.transfer_to(project). Manual-only (projects.md §6, §12-I):
    # a gem monitor belongs to whichever project its API key syncs into — moving it
    # here would just be undone on the next sync — so it's rejected and the UI tells
    # the user to re-point the app's key instead.
    #
    # Tenant/cross-project scoping is the controller's job (it resolves the target
    # through current_user.projects); this operation only enforces the domain rules
    # and turns a target-index collision into a clean error rather than a 500.
    class Transfer
      Result = Struct.new(:ok?, :error)

      def initialize(monitor)
        @monitor = monitor
      end

      def transfer_to(project)
        return Result.new(false, :not_manual) unless @monitor.source == "manual"
        return Result.new(true, nil) if @monitor.project_id == project.id

        @monitor.update!(project: project)
        Result.new(true, nil)
      rescue ActiveRecord::RecordNotUnique
        # The target already holds a monitor with this registration_key — the
        # partial unique index (project_id, registration_key) fired. Report it,
        # don't crash.
        Result.new(false, :collision)
      end
    end
  end
end
