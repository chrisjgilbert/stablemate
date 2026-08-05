require "test_helper"

# Pay still defaults automount_routes to true, which would hand us two surfaces
# we never asked for. pay.rb turns it off; this is the check that it stayed off.
#
# Asked as requests rather than of the routing table: a 404 is the behaviour that
# matters, and `routes.recognize_path` can only tell you about a data structure.
class PayEngineRoutesTest < ActionDispatch::IntegrationTest
  # The dangerous one. Pay draws this unconditionally — no Stripe keys needed —
  # and the page embeds the PaymentIntent's client_secret to nobody in particular.
  test "Pay's payment page is not reachable" do
    get "/pay/payments/1"

    assert_response :not_found
  end

  # Pay only draws its own webhook route when Stripe keys are present at BOOT, so
  # in this environment there is nothing to reach either way and this cannot fail
  # for the right reason. It is here because the path must 404 on every instance,
  # and because a reader looking for "did we close the second webhook?" should
  # find an answer next to the first one rather than conclude nobody checked.
  #
  # What actually guards the managed instance is Billing::WebhooksController being
  # the only Stripe entry point we route, plus the ProcessedEvent idempotency and
  # livemode gate it applies — all covered in billing/webhooks_controller_test.
  test "Pay's own webhook endpoint is not reachable" do
    post "/pay/webhooks/stripe"

    assert_response :not_found
  end
end
