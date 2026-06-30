require "application_system_test_case"

# The public marketing landing page (GET /) recreated from the design handoff.
# Anonymous visitors see the full marketing page; signed-in users are bounced to
# their dashboard. Browser-driven so the rendered nav/sections/CTAs are exercised.
class LandingPageTest < ApplicationSystemTestCase
  test "anonymous visitor sees the marketing landing page and its sections" do
    visit root_path

    # Hero — brand headline and the primary CTA.
    assert_text "Dead simple cron monitoring for Rails applications"
    assert_link "Start monitoring free"

    # Each marketing section is rendered.
    assert_text "Live in three steps, no agent to install"
    assert_text "Everything you need, nothing you don't"
    assert_text "Your recurring.yml is the spec"
    assert_text "Know the moment a job goes quiet"

    # Nav offers both entry points into the app.
    assert_link "Sign in"
    assert_link "Start free"
  end

  test "the Start monitoring free CTA leads to sign up" do
    visit root_path
    # The CTA appears in both the hero and the final band; the hero one is first.
    click_on "Start monitoring free", match: :first
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
