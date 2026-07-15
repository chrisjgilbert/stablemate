require "application_system_test_case"

# GET /pricing (issue #45) — public marketing pricing page. Browser-driven per
# CLAUDE.md's system-test rule: it's a user-facing flow, so a request test alone
# isn't enough — this exercises the rendered page and its CTAs in a real browser.
class PricingPageTest < ApplicationSystemTestCase
  FREE = Stablemate::FREE_PLAN_MONITOR_LIMIT
  PRO  = Stablemate::PRO_PLAN_MONITOR_LIMIT

  test "an anonymous visitor sees both plans and the CTAs send them to sign up" do
    visit pricing_path

    assert_text "Pricing"
    assert_text "Free"
    assert_text "Pro"
    assert_text "#{FREE} monitors"
    assert_text "#{PRO} monitors"

    # Self-host band: unlimited, AGPLv3, links to the guide + GitHub.
    assert_text "AGPLv3"
    assert_link "View on GitHub"

    # A handful of real FAQ objections.
    assert_text "self-host"

    # Neither plan card can buy Pro without an account — both CTAs go to sign-up.
    within all(".plan")[0] do
      click_on "Start free"
    end
    assert_current_path sign_up_path

    visit pricing_path
    within all(".plan")[1] do
      click_on "Start free"
    end
    assert_current_path sign_up_path
  end

  test "a signed-in free user on a billing-enabled instance upgrades straight from pricing" do
    with_billing_enabled do
      user = users(:alice)
      user.monitors.delete_all
      sign_in user

      visit pricing_path
      within all(".plan")[1] do
        click_on "Upgrade to Pro"
      end

      # Checkout redirects to Stripe's hosted page (no card data touches us) — in
      # the test env there's no configured Price ID, so CheckoutsController bounces
      # back with an alert instead of a real Stripe URL. Either way, the click
      # reached the real checkout action rather than being routed to sign-up.
      assert_no_current_path sign_up_path
      assert_text "Pro plan isn't configured"
    end
  end
end
