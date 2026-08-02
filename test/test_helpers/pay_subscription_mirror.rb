# The one way tests put a user on Pro without touching Stripe.
#
# Pay keeps a LOCAL mirror of Stripe's state (the pay_customers /
# pay_subscriptions tables) which webhooks refresh; almost every billing test
# needs a user who already has that mirror populated, and none of them want a
# network round trip to produce it. Eight test files had each grown their own
# six-line copy of these two writes under a different name, which is eight places
# to update when Pay's schema or our "pro" product name moves.
#
# Included into every test case (see test_helper.rb), so no `include` line is
# needed. Returns the Pay::Subscription; its `.customer` is the Pay::Customer.
module PaySubscriptionMirror
  # `status:` is what makes this useful beyond the happy path — `past_due`,
  # `incomplete` and `canceled` are the statuses our plan/cancel/upgrade
  # decisions actually turn on (see User::Subscription's TERMINAL_STATUSES and
  # UNBILLABLE_STATUSES). Ids default to random ones; pass them when a Stripe
  # stub or an assert_requested matcher has to name the same object.
  def give_pro_subscription!(user: @user, status: "active",
    customer_id: "cus_#{SecureRandom.hex(6)}",
    subscription_id: "sub_#{SecureRandom.hex(6)}")
    customer = user.set_payment_processor(:stripe)
    customer.update!(processor_id: customer_id)
    customer.subscriptions.create!(
      name: "pro", processor_id: subscription_id,
      processor_plan: "price_pro", status: status, quantity: 1
    )
  end
end
