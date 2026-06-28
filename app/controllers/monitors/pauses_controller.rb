module Monitors
  # Sub-resource replacing a custom POST /:id/pause verb: pausing *is* creating
  # the monitor's pause; resuming is destroying it. Delegates to the Pausing
  # concern on the record. Tenant-scoped via current_user.monitors.
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
      def set_monitor
        @monitor = current_user.monitors.find(params[:monitor_id])
      end
  end
end
