module Api
  module V1
    module Monitors
      # POST /api/v1/monitors/:id/rotate — rotate the monitor's ping_token,
      # invalidating the old ping URL. Named for the noun; path kept per the PRD.
      class PingTokensController < BaseController
        def update
          monitor = find_monitor
          monitor.rotate_ping_token!
          render json: { id: monitor.id, ping_url: ping_url_for(monitor) }
        end
      end
    end
  end
end
