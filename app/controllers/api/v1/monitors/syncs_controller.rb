module Api
  module V1
    module Monitors
      # POST /api/v1/monitors/sync — idempotent bulk upsert from the gem. Thin:
      # delegates to the project.sync_monitors operation (Project::MonitorSync),
      # which owns the upsert + graceful-partial cap logic. The project comes from
      # the API key (Design B), so the gem needs no protocol change. The top-level
      # `app` is still accepted — recorded as advisory last_synced_app (§3.2) and
      # kept for old-gem back-compat. (projects.md §9)
      class SyncsController < BaseController
        def create
          result = current_project.sync_monitors(app: sync_params[:app], entries: sync_entries)
          log_shared_key_conflicts(result[:conflicts])

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
          # Shared-key collision detection (§13-B3): two apps that share one project
          # key sync the same registration_key and silently mask each other. The
          # response envelope stays unchanged for old-gem back-compat (§9) and the
          # durable dashboard flag is future work, so until then surface the collision
          # in the logs rather than dropping the signal on the floor.
          def log_shared_key_conflicts(conflicts)
            return if conflicts.blank?

            Rails.logger.warn(
              "[stablemate] shared-key sync collision in project #{current_project.id}: " \
              "registration_key(s) #{conflicts.join(', ')} were last synced by a different " \
              "app than #{sync_params[:app].inspect}"
            )
          end

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
