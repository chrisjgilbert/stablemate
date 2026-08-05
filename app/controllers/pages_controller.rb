class PagesController < ApplicationController
  PUBLIC_PAGES = %i[home pricing terms privacy].freeze

  allow_unauthenticated_access only: PUBLIC_PAGES

  layout "landing", only: PUBLIC_PAGES

  def home
    if authenticated?
      # Keep any flash (e.g. the post-signup "Welcome") alive across this bounce
      # to the dashboard — without flash.keep the /home request consumes it.
      flash.keep
      redirect_to monitors_path
    end
  end

  def pricing
  end

  def terms
  end

  def privacy
  end
end
