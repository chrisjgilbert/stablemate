require "test_helper"

# Development mail must not reach real people.
#
# NonProdMailGuard registers from an `on_load(:action_mailer)` hook that runs
# only OUTSIDE production and test, so the test environment never executes that
# branch. Development is the one environment nothing else enters, and that single
# live registration is what stands between a dev box and a real inbox.
#
# Asserted by DELIVERING a message rather than by reading Mail's interceptor
# list: the behaviour is "a message aimed at a stranger does not go out", and the
# list is only how that currently happens. The guard's own rules are exercised
# directly, without a boot, in test/mailers/non_prod_mail_guard_test.rb.
class DevelopmentBootTest < ActiveSupport::TestCase
  include BootTestHelper

  # :smtp because the guard deliberately ignores local delivery methods
  # (letter_opener, file, test) — there is nothing to protect when the mail never
  # leaves the machine. With every recipient stripped the guard also clears
  # perform_deliveries, so `deliver` makes no network attempt.
  SCRIPT = <<~'RUBY'.freeze
    ActionMailer::Base # force the load that fires the on_load hook
    message = Mail.new(from: "alerts@stablemate.dev", to: [ "stranger@example.com" ],
                       cc: [ "cc@example.com" ], subject: "hi", body: "x")
    message.delivery_method :smtp
    # Rescued so an ATTEMPTED send is reported as a finding rather than crashing
    # the child — without the guard this reaches a real SMTP connection, and
    # "app failed to boot" would send the reader to entirely the wrong place.
    attempted = begin
      message.deliver
      nil
    rescue => e
      e.class.name
    end
    puts({ env: Rails.env.to_s, to: message.to, cc: message.cc,
           delivered: message.perform_deliveries, attempted_send: attempted }.to_json)
  RUBY

  test "a development instance will not deliver mail to someone off the allowlist" do
    config = boot_app(SCRIPT, "RAILS_ENV" => "development", "MAIL_ALLOWLIST" => nil)

    assert_equal "development", config["env"]
    assert_empty Array(config["to"]), "a stranger's address must be stripped in development"
    assert_empty Array(config["cc"]), "cc is a recipient too"
    assert_equal false, config["delivered"],
      "with no recipient left, development must abandon the send rather than attempt it"
    assert_nil config["attempted_send"],
      "development reached the network for a stranger's address — the guard is not registered"
  end

  # Only the DENY path is asserted here. The allow path would really deliver —
  # that is the point of it — and a boot test that opens an SMTP connection is a
  # test that fails on a machine without a mail server. What survives the
  # allowlist is exercised in-process, message by message, in
  # test/mailers/non_prod_mail_guard_test.rb.
end
