class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Tenant-scoped lookups (current_user.monitors.find(...)) raise RecordNotFound
  # for a foreign id; surface that as an opaque 404 so cross-tenant access is
  # indistinguishable from a non-existent record (no existence leak).
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  helper_method :current_user

  private
    def current_user
      Current.user
    end

    def render_not_found
      render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
    end
end
