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
      # Scoped through the cap rule itself, so a forged request against a monitor
      # that occupies no slot is an opaque 404 rather than a way back in. Its
      # complement is exactly `suspended` and `retired`, and pausing either takes
      # back a slot they had given up: `paused` DOES count (locked decision #8),
      # within_monitor_cap validates on: :create only, and resume! then flips
      # straight to `up` — so pause-then-resume walked a downgraded user's
      # suspended monitors back into live monitoring on the Free plan, and a
      # retired one back out of a prune only a sync may undo. Hiding the buttons
      # (monitors/show) is the affordance; this is the guard.
      def set_monitor
        @monitor = current_user.monitors.counting_toward_cap.find(params[:monitor_id])
      end
  end
end
