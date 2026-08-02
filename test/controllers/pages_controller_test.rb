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
    assert_no_match(/upgrade|\$\d|£\d|per month|\/mo\b/i, response.body)
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

  # A signed-in Free user on a billing-DISABLED (self-host) instance has
  # nothing to buy — the Pro CTA must not fall through to the anonymous
  # "Start free" sign-up link (that would send an existing account back to
  # registration). It gets sent to their dashboard instead, same as Free.
  test "a signed-in free user on a billing-disabled instance never sees sign-up CTAs" do
    with_billing_disabled do
      sign_in users(:alice)
      get pricing_path
      assert_response :success
      assert_select "a[href=?]", sign_up_path, count: 0
      assert_select "a[href=?]", monitors_path, minimum: 1
    end
  end

  # Signed-in visitors reach /pricing directly (unlike the root, it doesn't
  # redirect them away) — the shared nav/footer must reflect that instead of
  # offering "Sign in" / "Start free" to someone already signed in.
  test "a signed-in visitor's nav on the pricing page offers their dashboard, not sign-up" do
    sign_in users(:alice)
    get pricing_path
    assert_response :success
    assert_select "a[href=?]", sign_in_path, count: 0
    assert_select "a[href=?]", monitors_path, minimum: 2 # nav + colophon
  end

  # ---- Legal pages (WS-C) --------------------------------------------------
  # /terms and /privacy are published documents, not app chrome. They must render
  # for everyone — anonymous, signed in, and on a keyless self-host instance
  # where the whole Billing:: namespace 404s — on the same marketing layout as
  # the other .lp pages (body > div.lp is unique to layouts/landing).
  LEGAL_PAGES = { "/terms" => "Terms of Service", "/privacy" => "Privacy Policy" }.freeze

  test "the legal pages are public and render on the marketing layout" do
    LEGAL_PAGES.each do |path, heading|
      get path
      assert_response :success, "#{path} should be public"
      assert_select "body > div.lp", 1, "#{path} should render on layouts/landing"
      assert_select "h1", text: heading
      assert_select ".colophon" # the shared marketing footer rides along
    end
  end

  test "the legal pages stay reachable while signed in" do
    sign_in users(:alice)

    LEGAL_PAGES.each_key do |path|
      get path
      assert_response :success, "#{path} should not redirect a signed-in visitor"
      assert_select "body > div.lp", 1
    end
  end

  # The billing config-gate 404s the Billing:: namespace on a self-host instance;
  # it must never take the legal pages with it (a self-hoster's users read the
  # same terms as anyone else's).
  test "the legal pages render even when billing is disabled (self-host default)" do
    with_billing_disabled do
      LEGAL_PAGES.each_key do |path|
        get path
        assert_response :success, "#{path} should be unaffected by the billing gate"
      end
    end
  end

  # The documents cross-reference each other, so each one has to link to the
  # other — a policy that names a terms page nobody can reach is not much use.
  test "each legal page links to the other and to support" do
    get terms_path
    assert_select "a[href=?]", privacy_path, minimum: 1
    assert_select "a[href^=?]", "mailto:support@stablemate.dev", minimum: 1

    get privacy_path
    assert_select "a[href=?]", terms_path, minimum: 1
    assert_select "a[href^=?]", "mailto:support@stablemate.dev", minimum: 1
  end

  # The colophon is the only route to the legal pair from the marketing pages,
  # and every .lp page renders it — including the legal pages themselves, so a
  # reader can get from one document to the other without the back button.
  test "the marketing footer links to both legal documents from every marketing page" do
    [ root_path, pricing_path, terms_path, privacy_path ].each do |path|
      get path
      assert_select ".colophon a[href=?]", terms_path, { minimum: 1 }, "#{path}'s footer should link to /terms"
      assert_select ".colophon a[href=?]", privacy_path, { minimum: 1 }, "#{path}'s footer should link to /privacy"
    end
  end

  # The specifics a reader (and a regulator) needs to find, and that the rest of
  # the codebase has to keep true. Each is asserted because it is a *claim about
  # the code*, not decoration.
  test "the terms state the settled billing and jurisdiction terms" do
    get terms_path
    assert_match(/England and Wales/, response.body)
    assert_match(/AGPL/, response.body)
    assert_match(/#{Stablemate::DOWNGRADE_GRACE_PERIOD.in_days.to_i} days/, response.body)
    assert_match(/no.{0,3}SLA|service.level agreement/i, response.body)
    assert_match(/Last updated/, response.body)
  end

  # The repository ships TWO licences, deliberately and differently: the app is
  # AGPLv3 (LICENSE) and the companion gem is MIT (gem/LICENSE,
  # gem/stablemate.gemspec, gem/README.md — "intentionally more permissive than
  # the Stablemate server"). Of everything on these two pages, a misstated
  # licence is the claim a reader is most likely to rely on and act upon.
  test "the terms state each licence this repository actually ships" do
    repo = ApplicationController.helpers.stablemate_repo_url

    get terms_path
    assert_select "a[href=?]", "#{repo}/blob/main/LICENSE"
    assert_select "a[href=?]", "#{repo}/blob/main/gem/LICENSE"
    assert_match(/AGPL/, response.body)
    assert_match(/MIT/, response.body)
  end

  test "the privacy policy names what the code actually collects, keeps and shares" do
    get privacy_path
    # Retention and truncation come from the constants, never a hardcoded figure.
    assert_match(/#{(Stablemate::PING_RETENTION / 1.day).to_i} days/, response.body)
    assert_match(
      /#{ActiveSupport::NumberHelper.number_to_delimited(Stablemate::ERROR_MESSAGE_LIMIT)} characters/,
      response.body
    )
    # Every subprocessor that actually receives data.
    %w[Hetzner Cloudflare Stripe Postmark Honeybadger Slack].each do |processor|
      assert_match(/#{processor}/, response.body, "#{processor} must be disclosed as a subprocessor")
    end
    # The two strictly-necessary cookies, by name.
    assert_match(/session_id/, response.body)
    assert_match(/_stablemate_session/, response.body)
    # The rights section has to tell a UK reader where to complain.
    assert_match(/Information Commissioner/, response.body)
    assert_match(/Last updated/, response.body)
  end
end
