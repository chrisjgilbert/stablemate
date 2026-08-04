require "test_helper"

# Development is the one environment nothing else boots.
#
# Test boots on every run (test_helper requires config/environment, so a raising
# initializer aborts the whole suite) and ProductionEnvConfigTest boots production.
# Development had no such cover — and it holds real code the others skip:
# mail_interceptor.rb registers NonProdMailGuard only outside production and test,
# so its single live branch runs in an environment no test entered. A typo there
# reached a developer's console, never CI.
#
# It also guards the boot-order assumption chunk 6 removed. That interceptor used
# to reference ActionMailer::Base at load time, which pulled in `require "mail"`
# and, by luck of alphabetical initializer order, satisfied pay.rb's undeclared
# need for ::Mail::Address. Both ends are fixed; this is what notices if a similar
# accidental dependency reappears.
class DevelopmentBootTest < ActiveSupport::TestCase
  include BootTestHelper

  # Touching ActionMailer::Base is deliberate and is half the assertion: the guard
  # registers from an `ActiveSupport.on_load(:action_mailer)` hook, so this proves
  # the hook fires when the mailer loads rather than at initializer time. Mail
  # itself is not loaded at boot any more — reading its interceptors before this
  # line would raise NameError, which is exactly the coupling we removed.
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
