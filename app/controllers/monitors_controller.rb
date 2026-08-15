class MonitorsController < ApplicationController
  before_action :set_monitor, only: %i[show destroy]

  def index
    @projects = current_user.projects.order(:created_at).to_a
    all = current_user.monitors.order(:created_at).to_a
    # Suspended and retired monitors are retained but not active: list them apart
    # so the active list and the "count / cap" header reflect only the monitors
    # that occupy a cap slot. They are listed separately from each other too —
    # a plan change brings one back, a sync brings the other back.
    @monitors, inactive = all.partition { |m| !m.suspended? && !m.retired? }
    @suspended_monitors, @retired_monitors = inactive.partition(&:suspended?)
    # Preload every row's sparkline ticks in one query (no per-row N+1).
    @mini_ticks = Monitoring::Monitor.mini_ticks_for(all.map(&:id))
  end

  def show
  end

  def destroy
    @monitor.destroy
    redirect_to monitors_path, notice: "Monitor deleted.", status: :see_other
  end

  private
    # Tenant scoping: always load through current_user.monitors so a foreign id
    # raises RecordNotFound -> 404 (no cross-tenant access, no existence leak).
    def set_monitor
      @monitor = current_user.monitors.find(params[:id])
    end
end
