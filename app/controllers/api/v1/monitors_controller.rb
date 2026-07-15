module Api
  module V1
    # Read endpoints for the caller's monitors. Scoped to the API key's project.
    class MonitorsController < BaseController
      def index
        monitors = current_project.monitors.order(:created_at)
        render json: { monitors: monitors.map { |m| monitor_json(m) } }
      end

      def show
        render json: monitor_detail_json(find_monitor)
      end
    end
  end
end
