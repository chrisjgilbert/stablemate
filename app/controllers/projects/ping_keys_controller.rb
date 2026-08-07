module Projects
  # Per-project ping-key management. Issuance shows the raw sm_ping_… token
  # exactly once. Both actions scope through current_user.projects, so a foreign
  # project OR a key from another project is an opaque 404 — and because ping keys
  # are their own table, an API key id here is a 404 too.
  class PingKeysController < ApplicationController
    include ProjectShowData

    before_action :set_project

    def create
      @ping_key, @raw_token = PingKey.issue(project: @project, name: key_name)
      @raw_token_label = "Ping key"
      load_project_show_data # after issue, so the new key shows in the masked list
      # Re-render the project page with the generate-once modal open (@raw_token).
      render "projects/show", status: :created
    end

    def destroy
      @project.ping_keys.find(params[:id]).destroy
      redirect_to @project, notice: "Ping key revoked.", status: :see_other
    end

    private
      def set_project
        @project = current_user.projects.find(params[:project_id])
      end

      def key_name
        params.dig(:ping_key, :name).presence || "Ping key"
      end
  end
end
