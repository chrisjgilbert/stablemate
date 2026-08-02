require "test_helper"

# Stripe webhook endpoint — the only writer of User.plan. Verifies signature
# checking, idempotency, and the plan sync in both directions (issue #19).
#
# We post real, Stripe-signed payloads (using the test signing secret) so the
# signature path is exercised end to end, and stub Pay's processing at the
# boundary — we never hit Stripe's API. We drive the plan change directly through
# the user's Pay subscription mirror so the controller's sync reflects it.
class Billing::WebhooksControllerTest < ActionDispatch::IntegrationTest
  include StripeApiStubs

  setup do
    @user = users(:bob)
    @project = @user.projects.sole
  end

  # Build a Stripe-signed request body for an event whose object carries a
  # customer id, then POST it to the webhook endpoint.
  # Default livemode: false — the test secret key (sk_test_…) puts the app in test
  # mode, so test-mode events are the ones it should act on.
  def post_event(type:, customer:, id: "evt_#{SecureRandom.hex(8)}", livemode: false, object: {})
    payload = {
      id: id, type: type, livemode: livemode,
      data: { object: {
        id: "obj_#{SecureRandom.hex(4)}", customer: customer,
        client_reference_id: nil, subscription: nil, payment_intent: nil
      }.merge(object) }
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

  # As every webhook payload below is addressed to a customer id, this returns
  # that id rather than the subscription.
  def make_pro!(processor_id: "cus_#{SecureRandom.hex(6)}")
    give_pro_subscription!(customer_id: processor_id)
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
        @user.pay_subscriptions.update_all(status: "canceled", ends_at: 1.minute.ago)

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
        a = @project.monitors.create!(name: "A", **{ expected_interval_seconds: 3600, grace_period_seconds: 300 })
        b = @project.monitors.create!(name: "B", **{ expected_interval_seconds: 3600, grace_period_seconds: 300 })
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

  # M5 / launch-readiness D9 — Pay's stock customer emails are off. Two reasons:
  # the payment_failed one is `deliver_now` from inside the ProcessedEvent
  # idempotency transaction (an SMTP failure would 500 the webhook, roll the claim
  # back, and have Stripe retry the whole event — now that production raises
  # delivery errors, that path is live), and the copy is Pay's unbranded default,
  # never reviewed. Our own alerting is deliberate and queued.
  test "a payment_failed event sends no Pay email" do
    with_billing_enabled do
      without_pay_stripe_network do
        cus = make_pro!
        subscription = @user.pay_subscriptions.sole
        # Pay's handler skips `incomplete` subscriptions; past_due is the real
        # dunning state, where it would mail the customer.
        subscription.update!(status: "past_due")

        assert_no_emails do
          assert_no_enqueued_emails do
            # The invoice shape Stripe has sent since API version 2025-03-31: the
            # subscription reference moved off the invoice and under
            # `parent.subscription_details`, which is where Pay 11 reads it.
            post_event(type: "invoice.payment_failed", customer: cus,
              object: { parent: { subscription_details: { subscription: subscription.processor_id } } })
          end
        end

        assert_response :ok
      end
    end
  end

  # WS-D: closing an account destroys its pay_customers, so an in-flight Stripe
  # event can arrive seconds later referencing a customer that no longer resolves
  # here. It MUST be acknowledged — Stripe retries a 500 for days, and every
  # retry is an exception we'd have to look at.
  test "an event for a deleted customer is acknowledged, not 500" do
    with_billing_enabled do
      without_pay_stripe_network do
        cus = make_pro!
        subscription = @user.pay_subscriptions.sole
        stub_stripe_subscription_cancel(subscription.processor_id)
        @user.close_account!

        %w[checkout.session.completed customer.subscription.deleted customer.subscription.updated].each do |type|
          post_event(type: type, customer: cus)
          assert_response :ok, "#{type} for a deleted customer must be acknowledged"
        end

        # The dangerous one: Pay's invoice handlers reach for the customer and
        # its owner (Pay 11 reads the post-2025-03-31 invoice shape).
        post_event(type: "invoice.payment_failed", customer: cus,
          object: { parent: { subscription_details: { subscription: subscription.processor_id } } })
        assert_response :ok
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
