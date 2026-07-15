require "test_helper"

# The non-prod mail guard (config/initializers/mail_interceptor.rb). The interceptor
# is not *registered* in the test env (test uses delivery_method :test), so we exercise
# the guard class directly.
class NonProdMailGuardTest < ActiveSupport::TestCase
  def build_message(to:, cc: [], bcc: [], via: :smtp)
    message = Mail.new(from: "alerts@stablemate.dev", to: to, cc: cc, bcc: bcc, subject: "hi", body: "x")
    message.delivery_method via # the guard only acts on network (SMTP) delivery
    message
  end

  def with_allowlist(value)
    prev = ENV["MAIL_ALLOWLIST"]
    ENV["MAIL_ALLOWLIST"] = value
    yield
  ensure
    ENV["MAIL_ALLOWLIST"] = prev
  end

  test "drops recipients not on the allowlist and halts delivery" do
    with_allowlist("me@allowed.test") do
      message = build_message(to: [ "stranger@example.com" ])
      NonProdMailGuard.delivering_email(message)

      assert_empty message.to
      assert_equal false, message.perform_deliveries
    end
  end

  test "keeps only allowlisted recipients (case-insensitive) and allows delivery" do
    with_allowlist("me@allowed.test") do
      message = build_message(to: [ "ME@Allowed.test", "stranger@example.com" ])
      NonProdMailGuard.delivering_email(message)

      assert_equal [ "me@allowed.test" ], message.to.map(&:downcase)
      assert_not_equal false, message.perform_deliveries
    end
  end

  test "filters cc and bcc too" do
    with_allowlist("me@allowed.test") do
      message = build_message(to: [ "me@allowed.test" ], cc: [ "leak@example.com" ], bcc: [ "leak2@example.com" ])
      NonProdMailGuard.delivering_email(message)

      assert_empty message.cc
      assert_empty message.bcc
    end
  end

  test "an unset (empty) allowlist denies everything" do
    with_allowlist("") do
      message = build_message(to: [ "anyone@allowed.test" ])
      NonProdMailGuard.delivering_email(message)

      assert_empty message.to
      assert_equal false, message.perform_deliveries
    end
  end

  test "local delivery methods (letter_opener/:test) pass through untouched" do
    with_allowlist("me@allowed.test") do
      message = build_message(to: [ "stranger@example.com" ], via: :test)
      NonProdMailGuard.delivering_email(message)

      assert_equal [ "stranger@example.com" ], message.to
      assert_not_equal false, message.perform_deliveries
    end
  end
end
