# Issue and revoke one of a project's two credentials (v1-scope §4). The API key
# registers monitors; the ping key rides every check-in.
#
# They are separate TABLES so that neither lookup can ever see the other's rows —
# but that invariant lives in the models, and nothing about it wants two copies of
# this controller. Each action here scopes through the association named by
# `credential_class`, so a key belonging to another project, or of the other kind,
# is an opaque 404 either way.
#
# Including controllers supply `credential_class` and `credential_label`.
module ProjectCredentialIssuance
  extend ActiveSupport::Concern
  include ProjectShowData

  included do
    before_action :set_project
  end

  def create
    _credential, @raw_token = credential_class.issue(project: @project, name: key_name)
    @raw_token_label = credential_label
    load_project_show_data # after issue, so the new key shows in the masked list
    # Re-render the project page with the generate-once modal open (@raw_token).
    render "projects/show", status: :created
  end

  def destroy
    credentials.find(params[:id]).destroy
    redirect_to @project, notice: "#{credential_label} revoked.", status: :see_other
  end

  private
    def set_project
      @project = current_user.projects.find(params[:project_id])
    end

    def credentials
      @project.public_send(credential_class.model_name.plural)
    end

    # An optional user-supplied name, defaulting to the credential's own label.
    # Nested params are read only when they ARE nested: a request sending
    # `?ping_key=x` or `?ping_key[]=x` makes this a String or an Array, and
    # Parameters#dig raises TypeError on both — a 500 where this line means "use
    # the default".
    def key_name
      submitted = params[credential_class.model_name.param_key]
      name = submitted[:name] if submitted.respond_to?(:permitted?)
      name.presence || credential_label
    end
end
