require "test_helper"
require "open3"

# F4 — Pay must not automount its own routes.
#
# Pay 8.3 defaults `automount_routes = true`, which mounts the engine at /pay and
# gives us two surfaces we never asked for:
#
#   * POST /pay/webhooks/stripe — a SECOND Stripe webhook endpoint, verified
#     against the same signing secret but bypassing Billing::ProcessedEvent
#     idempotency, the livemode gate and the plan sync. Point Stripe at it and a
#     paying customer stays on Free.
#   * GET /pay/payments/:id — unauthenticated, and the page embeds the
#     PaymentIntent's client_secret.
#
# Billing::WebhooksController is the only Stripe entry point we want, so the mount
# has to be gone. The webhook half of the mount is only DRAWN when Stripe keys are
# present (Pay::Stripe.enabled?), so the boot test below is the one that proves it
# for the managed instance; the routing test proves the payments half in-process.
class PayAutomountRoutesTest < ActiveSupport::TestCase
  PAY_PATHS = [ [ "/pay/webhooks/stripe", :post ], [ "/pay/payments/1", :get ] ].freeze

  test "Pay's automounted routes are not recognised" do
    with_billing_enabled do
      PAY_PATHS.each do |path, method|
        assert_raises ActionController::RoutingError, "#{method.to_s.upcase} #{path} should not route" do
          Rails.application.routes.recognize_path(path, method: method)
        end
      end
    end
  end

  test "a managed instance booted with Stripe keys mounts nothing at /pay" do
    script = <<~RUBY
      puts({
        automount_routes: Pay.automount_routes,
        billing_enabled: Stablemate.billing_enabled?,
        pay_paths: Rails.application.routes.routes.map { |r| r.path.spec.to_s }.grep(/pay/)
      }.to_json)
    RUBY
    env = {
      "RAILS_ENV" => "test",
      "STRIPE_PUBLISHABLE_KEY" => "pk_test_boot",
      "STRIPE_SECRET_KEY" => "sk_test_boot",
      "STRIPE_WEBHOOK_SECRET" => "whsec_test_boot"
    }
    out, err, status = Open3.capture3(env, "bin/rails", "runner", script, chdir: Rails.root.to_s)
    assert status.success?, "app failed to boot with Stripe keys: #{err}"
    cfg = JSON.parse(out.lines.last)

    assert_equal true, cfg["billing_enabled"], "expected the boot to have billing on"
    assert_equal false, cfg["automount_routes"]
    assert_empty cfg["pay_paths"], "Pay mounted routes at /pay"
  end
end
