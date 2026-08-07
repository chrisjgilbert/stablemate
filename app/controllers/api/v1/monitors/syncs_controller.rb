module Api
  module V1
    module Monitors
      # POST /api/v1/monitors/sync — idempotent bulk upsert from the gem. The
      # project comes from the API key, so the gem needs no protocol change; the
      # top-level `app` is still accepted for old-gem back-compat.
      class SyncsController < BaseController
        def create
          result = current_project.sync_monitors(
            app: sync_params[:app], entries: sync_entries,
            declared_keys: sync_params[:declared_keys], prune: prune?
          )
          log_shared_key_conflicts(result[:conflicts])

          render json: {
            monitors: result[:registered].map do |monitor|
              { registration_key: monitor.registration_key,
                ping_url: ping_url_for(monitor),
                status: monitor.status }
            end,
            skipped: result[:skipped],
            # Monitors this project holds that matched no task in this run, and —
            # on a prune run — the subset actually retired. Disjoint, so the CLI
            # prints each list as-is. A pre-0.2.0 gem reads neither key and is
            # unaffected by their presence.
            orphaned: result[:orphaned],
            retired: result[:retired]
          }
        end

        private
          # A rake task's flag arrives as a string ("1", "true") and a JSON client
          # sends a boolean; both mean the same thing. Absent means false, which is
          # every pre-0.2.0 gem.
          def prune?
            ActiveModel::Type::Boolean.new.cast(sync_params[:prune]).present?
          end

          # Two apps that share one project key sync the same registration_key and
          # silently mask each other. The response envelope stays unchanged for
          # old-gem back-compat and the durable dashboard flag is future work, so
          # until then surface the collision in the logs rather than dropping the
          # signal on the floor.
          def log_shared_key_conflicts(conflicts)
            return if conflicts.blank?

            Rails.logger.warn(
              "[stablemate] shared-key sync collision in project #{current_project.id}: " \
              "registration_key(s) #{conflicts.join(', ')} were last synced by a different " \
              "app than #{sync_params[:app].inspect}"
            )
          end

          def sync_params
            params.permit(:app, :prune, declared_keys: [],
                          monitors: [ :registration_key, :name, :expected_interval_seconds,
                                      :grace_period_seconds, :schedule ])
          end

          # The operation re-sanitizes each entry, but we also strip the payload to
          # the five allowed keys here so nothing unexpected reaches it.
          def sync_entries
            Array(sync_params[:monitors]).map(&:to_h)
          end
      end
    end
  end
end
