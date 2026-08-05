module Api
  module V1
    # Read endpoints for the caller's monitors. Scoped to the API key's project.
    class MonitorsController < BaseController
      def index
        monitors = current_project.monitors.order(:created_at)
        render json: { monitors: monitors.map { |monitor| present(monitor).summary } }
      end

      def show
        render json: present(find_monitor).detail
      end
    end
  end
end
