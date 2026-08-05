# Standard REST CRUD for a user's projects. Everything is scoped through
# current_user.projects, so a foreign/unknown id raises RecordNotFound -> an opaque
# 404 (no cross-tenant access, no existence leak).
class ProjectsController < ApplicationController
  include ProjectShowData

  before_action :set_project, only: %i[show edit update destroy]

  def index
    @projects = current_user.projects.order(:created_at).to_a
    # One grouped COUNT each for the whole list — no per-row N+1.
    @monitor_counts = current_user.monitors.group(:project_id).count
    @key_counts = current_user.api_keys.group(:project_id).count
  end

  def show
    # Shared with Projects::ApiKeysController#create so the two never drift.
    load_project_show_data
  end

  def new
    @project = current_user.projects.new
  end

  def create
    @project = current_user.projects.new(project_params)
    if @project.save
      redirect_to after_create_path, notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # Double-submit: two identical creates in flight both pass the uniqueness
    # validation (neither row is committed yet) and the loser's INSERT hits the
    # (user_id, name) unique index. Re-render the SAME friendly error an ordinary
    # duplicate produces rather than 500ing on the index.
    @project.errors.add(:name, :taken)
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    if @project.update(project_params)
      redirect_to @project, notice: "Project renamed."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    # The Stimulus gate disables the button client-side; this is the belt-and-braces
    # server check. Deleting cascades the project's monitors and all their history.
    if params[:confirm_name] == @project.name
      @project.destroy
      redirect_to projects_path, notice: "Project deleted.", status: :see_other
    else
      redirect_to edit_project_path(@project), alert: "Type the project name exactly to confirm deletion."
    end
  end

  private
    def set_project
      @project = current_user.projects.find(params[:id])
    end

    def project_params
      params.require(:project).permit(:name)
    end

    # After creating the first project from the "add a monitor" flow, return the
    # user to monitor creation. Kept as a stateless, explicitly-whitelisted param
    # (no open-redirect surface, no stale session) for this single origin. If a
    # second "create a project first" entry point appears, unify this with
    # Authentication#after_authentication_url instead of growing a branch per caller.
    def after_create_path
      params[:after] == "new_monitor" ? new_monitor_path : @project
    end
end
