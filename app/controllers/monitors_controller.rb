class MonitorsController < ApplicationController
  before_action :set_monitor, only: %i[show edit update destroy]
  before_action :load_projects, only: %i[new create]

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

  def new
    @project = resolve_project
    @monitor = @project.monitors.new(expected_interval_seconds: 3600, grace_period_seconds: 300)
  end

  def create
    @project = resolve_project
    @monitor = @project.monitors.new(monitor_params)
    @monitor.source = "manual"

    # Serialise the cap check-and-create on the user row: without the lock two
    # concurrent creates can both read count < limit and both insert, blowing past
    # the cap. Redirect/render stay outside the lock. The cap stays per-user across
    # projects — it reads the delegated monitor.user.
    if current_user.with_lock { @monitor.save }
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

    # With no projects, route through project creation first (halting the action via
    # redirect), so the actions below always have at least one project.
    def load_projects
      @projects = current_user.projects.order(:created_at).to_a
      redirect_to new_project_path(after: "new_monitor"),
        notice: "Create a project first — your monitor will live inside it." if @projects.empty?
    end

    # An explicit project_id (the form selector) is honoured only within the user's
    # own projects (foreign -> 404); otherwise the most-recent.
    def resolve_project
      id = params.dig(:monitor, :project_id)
      id.present? ? current_user.projects.find(id) : @projects.last
    end

    def monitor_params
      params.require(:monitor).permit(:name, :expected_interval_seconds, :grace_period_seconds)
    end
end
