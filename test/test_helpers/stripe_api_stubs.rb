require "webmock"

# HTTP-level Stripe stubs (issue #19). Rather than overriding Stripe SDK methods,
# we stub the real api.stripe.com REST endpoints so the genuine Stripe Ruby SDK
# and the Pay gem run end-to-end against them — request building, serialization,
# and response parsing are all exercised, only the network is faked. Paired with
# the WebMock net-connect lockdown in test_helper.rb.
#
# Each helper registers a WebMock stub and returns the fake object id so callers
# can assert on it. Mix into a test with `include StripeApiStubs`.
module StripeApiStubs
  STRIPE_API = "https://api.stripe.com".freeze

  # POST /v1/checkout/sessions → a hosted Checkout session with a redirect URL.
  def stub_stripe_checkout_session(url: "https://checkout.stripe.test/session", id: "cs_test_123")
    stub_request(:post, "#{STRIPE_API}/v1/checkout/sessions")
      .to_return(status: 200, headers: json_headers, body: {
        id: id, object: "checkout.session", url: url, mode: "subscription"
      }.to_json)
    url
  end

  # POST /v1/billing_portal/sessions → a hosted Customer Portal session.
  def stub_stripe_portal_session(url: "https://billing.stripe.test/portal", id: "bps_test_123")
    stub_request(:post, "#{STRIPE_API}/v1/billing_portal/sessions")
      .to_return(status: 200, headers: json_headers, body: {
        id: id, object: "billing_portal.session", url: url
      }.to_json)
    url
  end

  # DELETE /v1/subscriptions/:id (Stripe's "cancel now") → a canceled subscription.
  # The SDK appends ?expand[]=… query params, so match the path with a regex and
  # ignore the query. Pay parses the returned object to update its local mirror.
  def stub_stripe_subscription_cancel(subscription_id)
    stub_request(:delete, %r{\A#{Regexp.escape("#{STRIPE_API}/v1/subscriptions/#{subscription_id}")}(\?|\z)})
      .to_return(status: 200, headers: json_headers, body: {
        id: subscription_id, object: "subscription", status: "canceled",
        cancel_at_period_end: false, canceled_at: 1_700_000_000, ended_at: 1_700_000_000,
        current_period_end: 1_700_000_000, items: { object: "list", data: [] }
      }.to_json)
    subscription_id
  end

  # Make a Stripe endpoint fail, to exercise the controllers' rescue paths. Matches
  # the path regardless of any ?expand[]=… query the SDK appends (regex on path).
  def stub_stripe_error(method, path, status: 402)
    stub_request(method, %r{\A#{Regexp.escape("#{STRIPE_API}#{path}")}(\?|\z)})
      .to_return(status: status, headers: json_headers, body: {
        error: { type: "api_error", message: "Stripe is having a moment." }
      }.to_json)
  end

  private
    def json_headers
      { "Content-Type" => "application/json" }
    end
end
