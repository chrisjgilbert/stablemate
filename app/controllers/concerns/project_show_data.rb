# Shared by ProjectsController#show and the two key controllers' #create — each of
# which re-renders show with the shown-once key modal — so they never drift.
module ProjectShowData
  extend ActiveSupport::Concern

  private
    def load_project_show_data
      @monitors = @project.monitors.order(:created_at).to_a
      @mini_ticks = Monitoring::Monitor.mini_ticks_for(@monitors.map(&:id))
      @api_keys = @project.api_keys.order(created_at: :desc).to_a
      @ping_keys = @project.ping_keys.order(created_at: :desc).to_a
    end
end
