module Projects
  # Per-project API-key management. Issuance shows the raw sm_live_… token exactly
  # once. Both actions scope through current_user.projects, so a foreign project OR
  # a key from another project is an opaque 404.
  class ApiKeysController < ApplicationController
    include ProjectShowData

    before_action :set_project

    def create
      @api_key, @raw_token = ApiKey.issue(project: @project, name: key_name)
      @raw_token_label = "API key"
      load_project_show_data # after issue, so the new key shows in the masked list
      # Re-render the project page with the generate-once modal open (@raw_token).
      render "projects/show", status: :created
    end

    def destroy
      @project.api_keys.find(params[:id]).destroy
      redirect_to @project, notice: "API key revoked.", status: :see_other
    end

    private
      def set_project
        @project = current_user.projects.find(params[:project_id])
      end

      def key_name
        params.dig(:api_key, :name).presence || "API key"
      end
  end
end
