ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

# Network lockdown: no test may reach the real internet. Outbound HTTP is blocked
# so an accidental live Stripe call fails loudly instead of hitting the API (or
# hanging in CI). localhost stays open for the Capybara/Puma server and Cuprite's
# CDP connection to Chromium. The Stripe paths are tested end-to-end against
# stubbed api.stripe.com responses — see test_helpers/stripe_api_stubs.rb.
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)
require_relative "test_helpers/stripe_api_stubs"

# Toggle the hosted-tier billing config-gate around a block. Stripe keys drive
# Stablemate.billing_enabled? at runtime; rather than poke ENV/credentials we
# swap the predicate (and the keys callers read) for the duration of the block.
# Mirrors how the cap tests use stub_const for the #16 gate.
module BillingGateTestHelper
  def with_billing_enabled
    Stablemate.stub_billing(true) { yield }
  end

  def with_billing_disabled
    Stablemate.stub_billing(false) { yield }
  end

  # Neutralise the only Pay handler steps that would reach the Stripe API, so a
  # webhook can be processed end to end in tests without network. The test sets up
  # the Pay subscription mirror directly; in production these calls keep it fresh.
  def without_pay_stripe_network
    sub_original = Pay::Stripe::Subscription.method(:sync)
    Pay::Stripe::Subscription.define_singleton_method(:sync) { |*, **| nil }
    yield
  ensure
    Pay::Stripe::Subscription.define_singleton_method(:sync, sub_original)
  end
end

module Stablemate
  # Test-only fixed Stripe credentials used when billing is forced on. Never real
  # keys — just enough for the config-gate and signature verification in tests.
  TEST_STRIPE_PUBLISHABLE_KEY = "pk_test_stablemate".freeze
  TEST_STRIPE_SECRET_KEY      = "sk_test_stablemate".freeze
  TEST_STRIPE_WEBHOOK_SECRET  = "whsec_stablemate_test".freeze

  # Test-only: force billing_enabled? (and the Stripe keys it reads) for the
  # duration of a block, restoring the originals afterward (exception-safe).
  def self.stub_billing(value)
    originals = %i[billing_enabled? stripe_publishable_key stripe_secret_key stripe_webhook_secret]
      .to_h { |m| [ m, method(m) ] }
    # In the test env there are no keys at boot, so Pay::Stripe.setup never set
    # ::Stripe.api_key. HTTP-level tests drive the real SDK, which needs one — set
    # it to the test secret while billing is forced on, and restore afterwards.
    original_api_key = ::Stripe.api_key

    if value
      define_singleton_method(:billing_enabled?)       { true }
      define_singleton_method(:stripe_publishable_key) { TEST_STRIPE_PUBLISHABLE_KEY }
      define_singleton_method(:stripe_secret_key)      { TEST_STRIPE_SECRET_KEY }
      define_singleton_method(:stripe_webhook_secret)  { TEST_STRIPE_WEBHOOK_SECRET }
      ::Stripe.api_key = TEST_STRIPE_SECRET_KEY
    else
      define_singleton_method(:billing_enabled?) { false }
    end

    yield
  ensure
    originals.each { |m, impl| define_singleton_method(m, impl) }
    ::Stripe.api_key = original_api_key
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # The `monitors` fixture file maps to the namespaced model (see the
    # CLAUDE.md deviation note in Monitoring::Monitor).
    set_fixture_class monitors: Monitoring::Monitor

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include BillingGateTestHelper

    # Add more helper methods to be used by all tests here...
  end
end

module RequestSignInHelper
  # Sign in over the real session endpoint so the auth cookie is set exactly as
  # in production. Fixtures share the password "password1234".
  def sign_in(user, password: "password1234")
    post session_path, params: { email_address: user.email_address, password: password }
  end
end

module RateLimitingTestHelper
  # The ping limiter uses a dedicated in-process MemoryStore (see PingsController).
  # Clear it around a block so a test starts from a clean count and leaves no
  # residue for the next test (parallel workers each have their own store).
  def with_rate_limiting
    PingsController::RATE_LIMIT_STORE.clear
    yield
  ensure
    PingsController::RATE_LIMIT_STORE.clear
  end
end

class ActionDispatch::IntegrationTest
  include RequestSignInHelper
  include RateLimitingTestHelper
end
