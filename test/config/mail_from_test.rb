require "test_helper"

# Every address this app sends from must resolve from STABLEMATE_MAIL_FROM, and
# that includes the ones Pay sends.
#
# Pay picks its from-address as `Pay.support_email || ::ApplicationMailer
# .default_params[:from]` (pay/app/mailers/pay/application_mailer.rb). Setting
# `config.support_email` therefore does not add an address — it OVERRIDES ours,
# and a hardcoded literal there is a domain a self-hoster does not own. Pay's own
# mailers are off today (`send_emails = false`), so the override is dormant, but
# the initializer documents how to switch them on in one line, and Pay::Receipts
# reads the same value. Leaving `Pay.support_email` unset is what makes the two
# agree for everyone.
#
# A boot test because initializers only run at boot: pay.rb reads the env once,
# and the already-booted suite can't re-run it under a different one.
class MailFromTest < ActiveSupport::TestCase
  include BootTestHelper

  SCRIPT = <<~RUBY.freeze
    puts({
      support_email: Pay.support_email&.to_s,
      pay_from: Pay::ApplicationMailer.default[:from].to_s,
      app_from: ApplicationMailer.default[:from].to_s
    }.to_json)
  RUBY

  test "Pay sends from the address STABLEMATE_MAIL_FROM sets, not a hardcoded one" do
    address = "Ops <ops@self-hosted.example>"
    config = boot_app(SCRIPT, "STABLEMATE_MAIL_FROM" => address)

    assert_nil config["support_email"],
      "Pay.support_email must stay unset so Pay inherits ApplicationMailer's from-address"
    assert_equal address, config["app_from"]
    assert_equal address, config["pay_from"],
      "Pay's from-address must follow STABLEMATE_MAIL_FROM like every other mailer"
  end
end
