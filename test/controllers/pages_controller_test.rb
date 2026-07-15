require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  # The marketing landing page is the public root for anonymous visitors.
  test "anonymous visitors see the marketing landing page at the root" do
    get root_path
    assert_response :success
    assert_select "h1"
    assert_select "a[href=?]", sign_up_path
  end

  # Signed-in users don't see marketing — the root takes them to their dashboard.
  test "signed-in users are sent from the root to their dashboard" do
    sign_in users(:alice)
    get root_path
    assert_redirected_to monitors_path
  end

  # The landing page links to the pricing page but never hardcodes a figure
  # itself — the numbers live on /pricing, sourced from the plan constants.
  test "the landing page links to pricing without hardcoding a price" do
    get root_path
    assert_select "a[href=?]", pricing_path, text: "Pricing"
    assert_no_match(/\$\d|£\d|per month|\/mo\b/i, response.body)
  end

  # GET /pricing (issue #45) — public marketing page, no auth required.
  test "the pricing page is public and shows both plans with their real limits" do
    get pricing_path
    assert_response :success
    assert_select "a[href=?]", sign_up_path
    assert_match(/Free/, response.body)
    assert_match(/Pro/, response.body)
    assert_match(/#{Stablemate::FREE_PLAN_MONITOR_LIMIT}/, response.body)
    assert_match(/#{Stablemate::PRO_PLAN_MONITOR_LIMIT}/, response.body)
  end

  # It renders regardless of the billing config-gate — it's marketing, not a
  # billing surface (unlike the Billing:: namespace, which 404s when keyless).
  test "the pricing page renders even when billing is disabled (self-host default)" do
    with_billing_disabled do
      get pricing_path
      assert_response :success
    end
  end

  # Anonymous visitors can't buy Pro without an account — both CTAs go to sign-up.
  test "an anonymous visitor's Pro CTA routes to sign-up, not straight to checkout" do
    get pricing_path
    assert_response :success
    assert_select "form[action=?]", billing_checkout_path, count: 0
  end

  # A signed-in Free user on a billing-enabled instance gets a direct upgrade
  # button (issue #45: "cheap to do" — skip the sign-up detour they don't need).
  test "a signed-in free user on a billing-enabled instance can upgrade directly from pricing" do
    with_billing_enabled do
      sign_in users(:alice)
      get pricing_path
      assert_response :success
      assert_select "form[action=?]", billing_checkout_path
    end
  end
end
