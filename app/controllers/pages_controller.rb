class PagesController < ApplicationController
  # Every page here is public. Signed-in users skip the landing page and go
  # straight to their dashboard; pricing and the two legal documents stay visible
  # to everyone, signed in or not — they're publications, not app chrome.
  PUBLIC_PAGES = %i[home pricing terms privacy].freeze

  allow_unauthenticated_access only: PUBLIC_PAGES

  # They render full-bleed — their own nav/footer and full-width sections — so
  # they opt out of the constrained authenticated app chrome.
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

  # The legal pair (WS-C). Static documents — no ivars, no branching: everything
  # a reader sees is in the view, and the figures it quotes come from the
  # Stablemate constants so the policy can't drift from the code.
  def terms
  end

  def privacy
  end
end
