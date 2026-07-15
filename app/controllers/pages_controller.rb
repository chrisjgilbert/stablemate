class PagesController < ApplicationController
  # The marketing landing and pricing pages are public. Signed-in users skip the
  # landing page and go straight to their dashboard; pricing stays visible to
  # everyone, signed in or not — it's marketing, not app chrome.
  allow_unauthenticated_access only: %i[home pricing]

  # Both render full-bleed — their own nav/footer and full-width sections — so
  # they opt out of the constrained authenticated app chrome.
  layout "landing", only: %i[home pricing]

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
end
