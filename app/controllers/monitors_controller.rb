class MonitorsController < ApplicationController
  before_action :set_monitor, only: %i[show edit update destroy]
  # A monitor lives inside a project. Load the user's projects once for new/create
  # (the default pre-selection and the form selector reuse the same set); with none,
  # route the user through project creation first (§4.4, §13-S6).
  before_action :load_projects, only: %i[new create]

  def index
    # The user's projects drive the grouped dashboard and the zero-project empty
    # state (projects.md §6). The view groups rows by the monitors' project_id
    # column (no association load, no N+1) and looks each project up in @projects.
    @projects = current_user.projects.order(:created_at).to_a
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
    # Pre-select the passed project (a project's "New monitor" button) or the most
    # recent; resolve_project keeps an explicit id tenant-safe.
    @project = resolve_project
    @monitor = @project.monitors.new(expected_interval_seconds: 3600, grace_period_seconds: 300)
  end

  def create
    @project = resolve_project
    @monitor = @project.monitors.new(monitor_params)
    @monitor.source = "manual"

    # Serialise the cap check-and-create on the user row: without the lock two
    # concurrent creates can both read count < limit and both insert, blowing past
    # the cap (WU-3). with_lock reloads the user under FOR UPDATE so within_monitor_cap
    # re-counts against committed state. Redirect/render stay outside the lock. The
    # cap stays per-user (across projects) — it reads the delegated monitor.user.
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

    # The user's projects, loaded once for new/create. With none, route through
    # project creation first (halts the action via redirect) and return here after
    # (§4.4, §13-S6), so the actions below always have at least one project.
    def load_projects
      @projects = current_user.projects.order(:created_at).to_a
      redirect_to new_project_path(after: "new_monitor"),
        notice: "Create a project first — your monitor will live inside it." if @projects.empty?
    end

    # The project this monitor belongs to. An explicit project_id (the form selector)
    # is honoured only within the user's own projects (foreign -> 404); otherwise the
    # most-recent. Runs after load_projects, so @projects is present and non-empty.
    def resolve_project
      id = params.dig(:monitor, :project_id)
      id.present? ? current_user.projects.find(id) : @projects.last
    end

    def monitor_params
      params.require(:monitor).permit(:name, :expected_interval_seconds, :grace_period_seconds)
    end
end
