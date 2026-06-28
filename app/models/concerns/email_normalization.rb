# Shared email normalization (trim + downcase), applied wherever an email
# address is stored (User, WaitlistSignup) so the rule lives in one place.
# `normalizes` skips nil by default; the `to_s` keeps it safe for blank input.
module EmailNormalization
  extend ActiveSupport::Concern

  included do
    normalizes :email_address, with: ->(e) { e.to_s.strip.downcase }
  end
end
