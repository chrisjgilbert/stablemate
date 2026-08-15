module Projects
  # The setup panel's "Generate setup command" button (v1-scope §7). A
  # sub-resource rather than a custom verb on ProjectsController: generating the
  # command IS creating the project's setup command, and the noun is what the
  # user is asking for.
  #
  # The response renders the project page with both raw keys in hand. That render
  # is the ONLY time either is readable — only their digests are stored — so
  # there is deliberately no show action to come back to.
  class SetupCommandsController < ApplicationController
    include ProjectShowData

    before_action :set_project

    def create
      @setup_pair = @project.issue_setup_pair!
      load_project_show_data # after issuing, so the masked lists include the new pair
      render "projects/show", status: :created
    end

    private
      def set_project
        @project = current_user.projects.find(params[:project_id])
      end
  end
end
