require "test_helper"

# Stripe webhook endpoint — the only writer of User.plan. Verifies signature
# checking, idempotency, and the plan sync in both directions (issue #19).
#
# We post real, Stripe-signed payloads (using the test signing secret) so the
# signature path is exercised end to end, and stub Pay's processing at the
# boundary — we never hit Stripe's API. We drive the plan change directly through
# the user's Pay subscription mirror so the controller's sync reflects it.
class Billing::WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:bob)
  end

  # Build a Stripe-signed request body for an event whose object carries a
  # customer id, then POST it to the webhook endpoint.
  # Default livemode: false — the test secret key (sk_test_…) puts the app in test
  # mode, so test-mode events are the ones it should act on.
  def post_event(type:, customer:, id: "evt_#{SecureRandom.hex(8)}", livemode: false)
    payload = {
      id: id, type: type, livemode: livemode,
      data: { object: {
        id: "obj_#{SecureRandom.hex(4)}", customer: customer,
        client_reference_id: nil, subscription: nil, payment_intent: nil
      } }
    }.to_json

    timestamp = Time.now
    signature = ::Stripe::Webhook::Signature.compute_signature(
      timestamp, payload, Stablemate::TEST_STRIPE_WEBHOOK_SECRET
    )
    header = ::Stripe::Webhook::Signature.generate_header(
      timestamp, signature, scheme: "v1"
    )

    post billing_webhook_path,
      params: payload,
      headers: { "Stripe-Signature" => header, "Content-Type" => "application/json" }
  end

  # Give the user a Stripe Pay::Customer and an active Pro subscription mirror so
  # subscribed_to_pro? is true (no Stripe API calls).
  def make_pro!(processor_id: "cus_#{SecureRandom.hex(6)}")
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: processor_id)
    customer.subscriptions.create!(
      name: "pro", processor_id: "sub_#{SecureRandom.hex(6)}",
      processor_plan: "price_pro", status: "active", quantity: 1
    )
    processor_id
  end

  test "a verified upgrade event flips plan to pro" do
    with_billing_enabled do
      without_pay_stripe_network do
        @user.update!(plan: "free")
        cus = make_pro!

        assert_difference -> { Billing::ProcessedEvent.count }, 1 do
          post_event(type: "checkout.session.completed", customer: cus)
        end

        assert_response :ok
        assert_equal "pro", @user.reload.plan
      end
    end
  end

  test "a verified cancel event flips plan back to free" do
    with_billing_enabled do
      without_pay_stripe_network do
        cus = make_pro!
        @user.update!(plan: "pro")

        # Cancel the mirror so subscribed_to_pro? becomes false.
        @user.subscriptions.update_all(status: "canceled", ends_at: 1.minute.ago)

        post_event(type: "customer.subscription.deleted", customer: cus)

        assert_response :ok
        assert_equal "free", @user.reload.plan
      end
    end
  end

  test "re-upgrade reactivates plan-suspended monitors up to the Pro cap" do
    with_billing_enabled do
      without_pay_stripe_network do
        # A user with two suspended monitors from an earlier downgrade.
        @user.update!(plan: "free")
        a = @user.monitors.create!(name: "A", **{ expected_interval_seconds: 3600, grace_period_seconds: 300 })
        b = @user.monitors.create!(name: "B", **{ expected_interval_seconds: 3600, grace_period_seconds: 300 })
        [ a, b ].each(&:suspend!)
        cus = make_pro!

        post_event(type: "customer.subscription.updated", customer: cus)

        assert_response :ok
        assert_equal "pro", @user.reload.plan
        refute a.reload.suspended?, "suspended monitor should be reactivated on re-upgrade"
        refute b.reload.suspended?
      end
    end
  end

  test "the same event id processed twice has one effect (idempotent)" do
    with_billing_enabled do
      without_pay_stripe_network do
        @user.update!(plan: "free")
        cus = make_pro!
        event_id = "evt_repeat_001"

        assert_difference -> { Billing::ProcessedEvent.count }, 1 do
          2.times { post_event(type: "checkout.session.completed", customer: cus, id: event_id) }
        end

        assert_response :ok
        assert_equal "pro", @user.reload.plan
      end
    end
  end

  test "a bad signature is rejected and never changes the plan" do
    with_billing_enabled do
      @user.update!(plan: "free")
      make_pro!

      post billing_webhook_path,
        params: { id: "evt_forged", type: "checkout.session.completed" }.to_json,
        headers: { "Stripe-Signature" => "t=1,v1=deadbeef", "Content-Type" => "application/json" }

      assert_response :bad_request
      assert_equal "free", @user.reload.plan
      assert_equal 0, Billing::ProcessedEvent.count
    end
  end

  test "an event from the other Stripe mode is acknowledged but never applied" do
    with_billing_enabled do
      without_pay_stripe_network do
        @user.update!(plan: "free")
        cus = make_pro!

        # App is in test mode (sk_test_…); a livemode:true event is the wrong mode.
        post_event(type: "checkout.session.completed", customer: cus, livemode: true)

        assert_response :ok
        assert_equal "free", @user.reload.plan
        assert_equal 0, Billing::ProcessedEvent.count
      end
    end
  end

  test "the webhook is an opaque 404 when billing is disabled (self-host)" do
    with_billing_disabled do
      post billing_webhook_path,
        params: "{}",
        headers: { "Stripe-Signature" => "t=1,v1=x", "Content-Type" => "application/json" }

      assert_response :not_found
    end
  end
end
