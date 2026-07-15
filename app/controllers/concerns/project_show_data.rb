# Loads everything projects/show renders for @project: its monitors (with the
# preloaded sparkline ticks the reused _row partial needs) and its masked API
# keys. Shared by ProjectsController#show and Projects::ApiKeysController#create —
# which re-renders show with the shown-once key modal — so the two never drift.
module ProjectShowData
  extend ActiveSupport::Concern

  private
    def load_project_show_data
      @monitors = @project.monitors.order(:created_at).to_a
      @mini_ticks = Monitoring::Monitor.mini_ticks_for(@monitors.map(&:id))
      @api_keys = @project.api_keys.order(created_at: :desc).to_a
    end
end
