require "application_system_test_case"

# The public marketing landing page (GET /) — the "Omakase" design direction.
# Anonymous visitors see the full marketing page; signed-in users are bounced to
# their dashboard. Browser-driven so the rendered nav/sections/CTAs are exercised.
class LandingPageTest < ApplicationSystemTestCase
  test "anonymous visitor sees the marketing landing page and its sections" do
    visit root_path

    # Hero — brand headline and the primary CTA.
    assert_text "Super simple job monitoring for Rails"
    assert_link "Start monitoring — free"

    # Each marketing section is rendered. Substrings are whitespace-safe:
    # Capybara normalises nbsp to a plain space.
    assert_text "It's genuinely this simple"
    assert_text "already the to-do list"
    assert_text "it's worth reading"
    assert_text "Free forever to self-host"
    assert_text "shouldn't be a"
    assert_text "9 a.m. surprise"

    # Nav offers both entry points into the app, plus the pre-launch badge.
    assert_link "Sign in"
    assert_link "Start free"
    assert_link "Coming soon", href: sign_up_path
  end

  test "the Start monitoring free CTA leads to sign up" do
    visit root_path
    # The CTA appears in both the hero and the finale; the hero one is first.
    click_on "Start monitoring — free", match: :first
    assert_current_path sign_up_path
  end

  # The landing page links out to /pricing but never states a figure itself —
  # the numbers live on the pricing page, sourced from the plan constants.
  test "the landing page links to pricing without stating a price itself" do
    visit root_path
    assert_link "Pricing", href: pricing_path
    assert_no_text(/\$\d/)
    assert_no_text(/£\d/)
    assert_no_text(/most popular/i)
  end

  test "the Pricing nav link leads to the pricing page" do
    visit root_path
    click_on "Pricing", match: :first
    assert_current_path pricing_path
  end

  # The colophon is the only way into the legal pair from the marketing pages
  # (WS-C), so both links must be there and must actually resolve. The static
  # pages get no system test of their own — a document is not a flow — but
  # reaching them is.
  test "the footer links reach the terms and the privacy policy" do
    visit root_path
    within "footer" do
      click_on "Terms of Service"
    end
    assert_current_path terms_path
    assert_text "Governing law"

    visit root_path
    within "footer" do
      click_on "Privacy Policy"
    end
    assert_current_path privacy_path
    assert_text "Cookies"
  end

  test "signed-in visitors are sent from the root to their dashboard" do
    sign_in users(:alice)
    visit root_path
    assert_current_path monitors_path
  end
end
