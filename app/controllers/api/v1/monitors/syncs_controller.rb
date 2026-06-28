module Api
  module V1
    module Monitors
      # POST /api/v1/monitors/sync — idempotent bulk upsert from the gem. Thin:
      # delegates to the user.sync_monitors operation (User::MonitorSync), which
      # owns the upsert + graceful-partial cap logic. (phase-3 §3.3)
      class SyncsController < BaseController
        def create
          result = current_user.sync_monitors(app: sync_params[:app], entries: sync_entries)

          render json: {
            monitors: result[:registered].map do |monitor|
              { registration_key: monitor.registration_key,
                ping_url: ping_url_for(monitor),
                status: monitor.status }
            end,
            skipped: result[:skipped]
          }
        end

        private
          def sync_params
            params.permit(:app, monitors: [ :registration_key, :name,
                                            :expected_interval_seconds, :grace_period_seconds ])
          end

          # The operation re-sanitizes each entry, but we also strip the payload to
          # the four allowed keys here so nothing unexpected reaches it.
          def sync_entries
            Array(sync_params[:monitors]).map(&:to_h)
          end
      end
    end
  end
end
