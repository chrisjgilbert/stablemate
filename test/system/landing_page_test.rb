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
    assert_text "No paid tier. No upsell"
    assert_text "shouldn't be a"
    assert_text "9 a.m. surprise"

    # Nav offers both entry points into the app.
    assert_link "Sign in"
    assert_link "Start free"
  end

  test "the Start monitoring free CTA leads to sign up" do
    visit root_path
    # The CTA appears in both the hero and the finale; the hero one is first.
    click_on "Start monitoring — free", match: :first
    assert_current_path sign_up_path
  end

  test "no pricing or paid-plan UI on the landing page (one free plan)" do
    visit root_path
    assert_no_text(/pricing/i)
    assert_no_text(/\$\d/)        # no dollar prices
    assert_no_text(/most popular/i)
  end

  test "signed-in visitors are sent from the root to their dashboard" do
    sign_in users(:alice)
    visit root_path
    assert_current_path monitors_path
  end
end
