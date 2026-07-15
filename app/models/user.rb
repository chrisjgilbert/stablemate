class User < ApplicationRecord
  include EmailNormalization
  include Plan, Verification, Subscription

  has_secure_password
  has_many :sessions, dependent: :destroy
  # Ownership flows monitor → project → user (docs/specs/projects.md §4.5). Reads
  # (cap counts, dashboard, downgrade) keep working through these `through`
  # associations; every build/create moves to project scope (a `through` can't
  # build). The gem-sync operation moved to Project::MonitorSync accordingly.
  has_many :projects, dependent: :destroy
  has_many :monitors, through: :projects, source: :monitors
  has_many :api_keys, through: :projects

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
