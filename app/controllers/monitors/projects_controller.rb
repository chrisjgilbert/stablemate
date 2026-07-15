module Monitors
  # Sub-resource replacing a custom POST /:id/move verb (CLAUDE.md rule 4): moving a
  # monitor *is* updating which project it belongs to. Manual monitors only — a gem
  # monitor is rejected with guidance to re-point its API key (projects.md §6, §12-I).
  # Both the monitor and the target project are resolved tenant-scoped, so a foreign
  # id on either side is an opaque 404.
  class ProjectsController < ApplicationController
    before_action :set_monitor

    def update
      target = current_user.projects.find(params[:project_id])
      result = @monitor.transfer_to(target)

      if result.ok?
        redirect_to target, notice: "#{@monitor.name} moved to #{target.name}."
      else
        redirect_to @monitor, alert: move_error(result.error)
      end
    end

    private
      def set_monitor
        @monitor = current_user.monitors.find(params[:monitor_id])
      end

      def move_error(reason)
        case reason
        when :not_manual
          "Gem-synced monitors move with their API key — re-point the app's key to the target project instead."
        when :collision
          "That project already has a monitor with the same key."
        else
          "Couldn't move that monitor."
        end
      end
  end
end
