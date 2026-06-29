class MonitorsController < ApplicationController
  before_action :set_monitor, only: %i[show edit update destroy]

  def index
    all = current_user.monitors.order(:created_at).to_a
    # Plan-suspended monitors (hosted tier) are retained but not active: list them
    # apart so the active list and the "count / cap" header reflect only the
    # monitors that occupy a cap slot (suspended ones don't — PRD §3.3).
    @monitors, @suspended_monitors = all.partition { |m| !m.suspended? }
    # Preload every row's sparkline ticks in one query (no per-row N+1).
    @mini_ticks = Monitoring::Monitor.mini_ticks_for(all.map(&:id))
  end

  def show
  end

  def new
    @monitor = current_user.monitors.new(
      expected_interval_seconds: 3600,
      grace_period_seconds: 300
    )
  end

  def create
    @monitor = current_user.monitors.new(monitor_params)
    @monitor.source = "manual"

    if @monitor.save
      redirect_to @monitor, notice: "Monitor created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @monitor.update(monitor_params)
      redirect_to @monitor, notice: "Monitor updated."
    else
      render :edit, status: :unprocessable_entity
    end
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

    def monitor_params
      params.require(:monitor).permit(:name, :expected_interval_seconds, :grace_period_seconds)
    end
end
