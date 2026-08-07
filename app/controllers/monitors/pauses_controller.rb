module Monitors
  # Sub-resource replacing a custom POST /:id/pause verb: pausing *is* creating
  # the monitor's pause; resuming is destroying it.
  class PausesController < ApplicationController
    before_action :set_monitor

    def create
      @monitor.pause!
      redirect_back_or_to @monitor, notice: "Monitor paused."
    end

    def destroy
      @monitor.resume!
      redirect_back_or_to @monitor, notice: "Monitor resumed."
    end

    private
      # Retired monitors are out of scope here, so a forged request is an opaque
      # 404 rather than a resurrection: pausing one would take back the cap slot
      # retirement freed, and resuming one would overwrite a state only a sync can
      # undo. The show page hides both buttons for the same reason it hides them
      # for `suspended`.
      def set_monitor
        @monitor = current_user.monitors.not_retired.find(params[:monitor_id])
      end
  end
end
