require "test_helper"

# WU-7 (M6) — Stripe mode detection must recognise restricted keys (rk_), not just
# secret keys (sk_). A live restricted key that read as test-mode would silently
# drop every real webhook, stranding paying customers on Free.
class StablemateLivemodeTest < ActiveSupport::TestCase
  def with_secret_key(key)
    original = Stablemate.method(:stripe_secret_key)
    Stablemate.define_singleton_method(:stripe_secret_key) { key }
    yield
  ensure
    Stablemate.define_singleton_method(:stripe_secret_key, original)
  end

  test "live secret and restricted keys are both live mode" do
    with_secret_key("sk_live_abc") { assert Stablemate.stripe_livemode? }
    with_secret_key("rk_live_abc") { assert Stablemate.stripe_livemode? }
  end

  test "test secret and restricted keys are both test mode" do
    with_secret_key("sk_test_abc") { refute Stablemate.stripe_livemode? }
    with_secret_key("rk_test_abc") { refute Stablemate.stripe_livemode? }
    with_secret_key(nil)           { refute Stablemate.stripe_livemode? }
  end
end
