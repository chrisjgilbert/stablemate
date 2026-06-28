class User < ApplicationRecord
  include EmailNormalization
  include Plan, Verification, MonitorSync

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :monitors, class_name: "Monitoring::Monitor", dependent: :destroy

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }
  validates :password, length: { minimum: 8 }, allow_nil: true

  # Signed, expiring token for the email-verification link (no extra column —
  # invalidated automatically once verified_at is set). Non-blocking: unverified
  # users are fully usable, this just confirms ownership.
  generates_token_for :email_verification, expires_in: 1.week do
    verified_at
  end

  # Signed, short-lived token for the password-reset link (Rails 8 standard).
  # Keyed off the password salt so the token self-invalidates once the password
  # changes — preventing reuse after a reset. Used by PasswordsController.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end
end
