ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # The `monitors` fixture file maps to the namespaced model (see the
    # CLAUDE.md deviation note in Monitoring::Monitor).
    set_fixture_class monitors: Monitoring::Monitor

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
