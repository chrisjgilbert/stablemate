module Settings
  # Session-authed, owner-only API-key management. Generate (shown once via a
  # modal), list (masked), revoke. (architecture.md §7 / phase-3 §3.5)
  class ApiKeysController < ApplicationController
    def index
      @api_keys = current_user.api_keys.order(created_at: :desc)
    end

    def create
      @api_key, @raw_token = ApiKey.issue(user: current_user, name: key_name)
      @api_keys = current_user.api_keys.order(created_at: :desc)
      # Re-render the index with the generate-once modal open showing @raw_token.
      render :index, status: :created
    end

    def destroy
      current_user.api_keys.find(params[:id]).destroy
      redirect_to settings_api_keys_path, notice: "API key revoked.", status: :see_other
    end

    private
      def key_name
        params.dig(:api_key, :name).presence || "API key"
      end
  end
end
