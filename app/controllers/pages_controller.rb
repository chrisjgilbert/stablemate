class PagesController < ApplicationController
  # The marketing landing page is public; signed-in users skip it and go straight
  # to their dashboard.
  allow_unauthenticated_access only: :home

  def home
    if authenticated?
      # Keep any flash (e.g. the post-signup "Welcome") alive across this bounce
      # to the dashboard — without flash.keep the /home request consumes it.
      flash.keep
      redirect_to monitors_path
    end
  end
end
