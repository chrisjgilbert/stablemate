module Api
  module V1
    # Read endpoints for the caller's monitors. Tenant-scoped via current_user.
    class MonitorsController < BaseController
      def index
        monitors = current_user.monitors.order(:created_at)
        render json: { monitors: monitors.map { |m| monitor_json(m) } }
      end

      def show
        render json: monitor_detail_json(find_monitor)
      end
    end
  end
end
