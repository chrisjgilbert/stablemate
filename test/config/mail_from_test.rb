require "test_helper"

# Every address this app sends from must resolve from STABLEMATE_MAIL_FROM,
# including the ones Pay sends: Pay picks its from-address as
# `Pay.support_email || ::ApplicationMailer.default_params[:from]`, so setting
# support_email would override ours with a domain a self-hoster doesn't own.
#
# A boot test because pay.rb reads the env once, at boot.
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
