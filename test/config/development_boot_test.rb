require "test_helper"

# Development is the one environment nothing else boots — the test env boots on
# every run and ProductionEnvConfigTest boots production. It also holds code the
# others skip: mail_interceptor.rb registers NonProdMailGuard only outside
# production and test, so its single live branch is what stops dev mail reaching
# real people and no test entered the environment that runs it.
class DevelopmentBootTest < ActiveSupport::TestCase
  include BootTestHelper

  # Touching ActionMailer::Base first is half the assertion: the guard registers
  # from an `ActiveSupport.on_load(:action_mailer)` hook, so this proves the hook
  # fires when the mailer loads rather than at initializer time.
  SCRIPT = <<~RUBY.freeze
    ActionMailer::Base
    registered = Mail.class_variable_get(:@@delivery_interceptors).map(&:to_s)
    puts({ env: Rails.env.to_s, interceptors: registered }.to_json)
  RUBY

  test "development boots, and the non-prod mail guard is actually registered" do
    config = boot_app(SCRIPT, "RAILS_ENV" => "development")

    assert_equal "development", config["env"]
    assert_includes config["interceptors"], "NonProdMailGuard",
      "NonProdMailGuard must be registered in development — it is the only " \
      "environment that runs it, and it is what stops dev mail reaching real people"
  end
end
