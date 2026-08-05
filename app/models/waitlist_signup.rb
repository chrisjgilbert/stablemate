# A launch waitlist entry, captured when the global account cap is reached. No
# login, no account — just an email we can invite later.
class WaitlistSignup < ApplicationRecord
  include EmailNormalization

  # No updated_at column (write-once); tell Active Record not to maintain it.
  self.record_timestamps = false

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }

  before_create { self.created_at ||= Time.current }
end
