module Monitors
  # Sub-resource replacing a custom POST /:id/rotate verb: rotating the token is
  # updating the monitor's (singular) ping_token. The old ping URL stops working
  # immediately. Tenant-scoped via current_user.monitors.
  class PingTokensController < ApplicationController
    before_action :set_monitor

    def update
      @monitor.rotate_ping_token!
      # One-shot signal to show.html.erb: render the (normally collapsed) ping
      # setup as the full top card so the freshly rotated URL is immediately
      # visible — the old one just died. Server-rendered on purpose: an anchored
      # redirect doesn't work here, because Turbo follows form redirects via
      # fetch, which drops the URL fragment before the browser ever sees it.
      flash[:reveal_ping_setup] = true
      redirect_to @monitor, notice: "Ping URL rotated. The old URL no longer works."
    end

    private
      def set_monitor
        @monitor = current_user.monitors.find(params[:monitor_id])
      end
  end
end
