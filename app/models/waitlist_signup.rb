# A launch waitlist entry, captured when the global account cap is reached
# (SIGNUP_ACCOUNT_CAP). No login, no account — just an email we can invite later.
# Created by the Signup coordinator's at-capacity branch; never edited (no
# updated_at), so a duplicate email is a friendly no-op rather than an error.
class WaitlistSignup < ApplicationRecord
  include EmailNormalization

  # No updated_at column (write-once); tell Active Record not to maintain it.
  self.record_timestamps = false

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }

  before_create { self.created_at ||= Time.current }
end
