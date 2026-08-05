ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/query_counting_test_helper"
require_relative "test_helpers/config_gate_test_helper"
require_relative "test_helpers/log_capture_test_helper"

# Network lockdown: no test may reach the real internet. Outbound HTTP is blocked
# so an accidental live Stripe call fails loudly instead of hitting the API (or
# hanging in CI). localhost stays open for the Capybara/Puma server and Cuprite's
# CDP connection to Chromium. The Stripe paths are tested end-to-end against
# stubbed api.stripe.com responses — see test_helpers/stripe_api_stubs.rb.
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)
require_relative "test_helpers/stripe_api_stubs"
require_relative "test_helpers/pay_subscription_mirror"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    # The `monitors` fixture file maps to the namespaced model.
    set_fixture_class monitors: Monitoring::Monitor

    fixtures :all

    include ConfigGateTestHelper
    include BillingGateTestHelper
    include SlackGateTestHelper
    include CloudflareAnalyticsTestHelper
    include PaySubscriptionMirror
    include QueryCountingTestHelper
    include LogCaptureTestHelper

    # The rate-limit stores persist across tests within a worker; clear them so
    # ordinary per-test requests never accumulate into a spurious throttle.
    setup do
      [ PingsController, RegistrationsController, Api::V1::BaseController, AccountCredentials ].each do |limiter|
        limiter::RATE_LIMIT_STORE.clear
      end
    end
  end
end

module RequestSignInHelper
  # Sign in over the real session endpoint so the auth cookie is set exactly as in
  # production. Fixtures share the password "password1234".
  def sign_in(user, password: "password1234")
    post session_path, params: { email_address: user.email_address, password: password }
  end
end

module RateLimitingTestHelper
  # Clear the ping limiter's store around a block so a test starts from a clean
  # count and leaves no residue for the next one.
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
