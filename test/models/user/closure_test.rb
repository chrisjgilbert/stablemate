require "test_helper"

# Account closure (launch-readiness §5 / WS-D). Deletion means more than
# `destroy!`: a Stripe subscription must never outlive its account, and Pay
# declares no `dependent:` on `pay_customers`, so the pay_* rows have to be taken
# down explicitly or they are left orphaned with a nil owner.
#
# Stripe is exercised at the HTTP boundary (the real SDK + Pay run against
# stubbed api.stripe.com responses) rather than by stubbing Pay's methods, so the
# cancel actually happens the way it does in production.
class User::ClosureTest < ActiveSupport::TestCase
  include StripeApiStubs

  setup do
    @user = users(:bob)
  end

  # Give the user a Stripe Pay::Customer with a live Pro subscription mirror.
  def make_pro!(status: "active")
    customer = @user.set_payment_processor(:stripe)
    customer.update!(processor_id: "cus_#{SecureRandom.hex(6)}")
    customer.subscriptions.create!(
      name: "pro", processor_id: "sub_#{SecureRandom.hex(6)}",
      processor_plan: "price_pro", status: status, quantity: 1
    )
  end

  # The rest of what a paying customer accumulates: a card on file and a receipt.
  # Both carry personal data (last4, amounts), so both have to go with the account.
  def add_billing_history!(subscription)
    customer = subscription.customer
    [
      customer.payment_methods.create!(processor_id: "pm_#{SecureRandom.hex(6)}",
        payment_method_type: "card", default: true, data: { brand: "Visa", last4: "4242" }),
      customer.charges.create!(processor_id: "ch_#{SecureRandom.hex(6)}",
        subscription: subscription, amount: 900, currency: "usd")
    ]
  end

  test "with billing on it cancels at Stripe, destroys the pay customers, then the user" do
    with_billing_enabled do
      subscription = make_pro!
      customer_id = subscription.customer_id
      payment_method, charge = add_billing_history!(subscription)
      stub_stripe_subscription_cancel(subscription.processor_id)

      @user.close_account!

      assert_requested :delete, %r{api\.stripe\.com/v1/subscriptions/#{subscription.processor_id}}
      assert_not User.exists?(@user.id), "the user row should be gone"
      assert_not Pay::Customer.exists?(customer_id), "the Pay::Customer must be destroyed explicitly"
      # Every pay_* row hangs off the customer, so this is the whole cascade the
      # explicit destroy is buying. A survivor here is a row of card/receipt data
      # with a nil owner — and the thing Pay's webhook handlers then blow up on.
      assert_not Pay::Subscription.exists?(subscription.id), "Pay::Customer cascades to its subscriptions"
      assert_not Pay::PaymentMethod.exists?(payment_method.id), "the card on file must go too"
      assert_not Pay::Charge.exists?(charge.id), "the receipts must go too"
      assert_empty Pay::Customer.where(owner_type: "User", owner_id: @user.id)
    end
  end

  # Local/Stripe drift: the mirror still says active, Stripe says the
  # subscription is gone. cancel_now! wraps that in Pay::Error — the policy is to
  # abort and delete NOTHING rather than half-close the account.
  test "a Stripe cancel failure aborts cleanly and deletes nothing" do
    with_billing_enabled do
      subscription = make_pro!
      customer_id = subscription.customer_id
      payment_method, charge = add_billing_history!(subscription)
      project = @user.projects.sole
      monitor_ids = project.monitors.ids
      stub_stripe_error(:delete, "/v1/subscriptions/#{subscription.processor_id}", status: 404)

      assert_raises(Pay::Error) { @user.close_account! }

      assert User.exists?(@user.id), "the user must survive a failed cancel"
      assert Pay::Customer.exists?(customer_id)
      assert Pay::Subscription.exists?(subscription.id)
      assert Pay::PaymentMethod.exists?(payment_method.id)
      assert Pay::Charge.exists?(charge.id)
      # "Delete nothing" has to mean the app-side rows too, not just the pay_* ones.
      assert Project.exists?(project.id)
      assert_equal monitor_ids.sort, project.monitors.reload.ids.sort
    end
  end

  # Self-host (keyless) instance: there is no Stripe to talk to. The lockdown in
  # test_helper turns any outbound call into a hard failure, so this also proves
  # closure never reaches the network when billing is off.
  test "with billing off it just destroys the user" do
    with_billing_disabled do
      @user.close_account!

      assert_not User.exists?(@user.id)
    end
  end

  test "closing an account cascades every record the user owns" do
    with_billing_disabled do
      project = @user.projects.sole
      monitor = project.monitors.first
      api_key, = ApiKey.issue(project: project, name: "gem")
      session = @user.sessions.create!(user_agent: "test", ip_address: "127.0.0.1")
      ping_event = monitor.ping_events.create!(received_at: Time.current, source_ip: "127.0.0.1")
      incident = monitor.incidents.create!(started_at: Time.current)
      stat = monitor.uptime_day_stats.create!(day: Date.current)
      notification = monitor.notifications.create!(event: "down", incident: incident)

      @user.close_account!

      assert_not Project.exists?(project.id)
      assert_not Monitoring::Monitor.exists?(monitor.id)
      assert_not ApiKey.exists?(api_key.id)
      assert_not Session.exists?(session.id)
      assert_not PingEvent.exists?(ping_event.id)
      assert_not Incident.exists?(incident.id)
      assert_not UptimeDayStat.exists?(stat.id)
      assert_not Notification.exists?(notification.id)
    end
  end
end
