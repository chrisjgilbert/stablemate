require "test_helper"

class WaitlistSignupTest < ActiveSupport::TestCase
  test "downcases and strips the email before saving" do
    signup = WaitlistSignup.create!(email_address: "  Wait@Example.com ")
    assert_equal "wait@example.com", signup.email_address
  end

  test "requires an email address" do
    signup = WaitlistSignup.new(email_address: "")
    assert_not signup.valid?
    assert signup.errors[:email_address].any?
  end

  test "email address is unique (case-insensitively, via normalization)" do
    WaitlistSignup.create!(email_address: "dupe@example.com")
    dup = WaitlistSignup.new(email_address: "DUPE@example.com")
    assert_not dup.valid?
    assert dup.errors[:email_address].any?
  end
end
