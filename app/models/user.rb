class User < ApplicationRecord
  include EmailNormalization
  include Plan, Verification, Subscription

  has_secure_password
  has_many :sessions, dependent: :destroy
  # Ownership flows monitor → project → user. Reads keep working through these
  # `through` associations; every build/create moves to project scope (a `through`
  # can't build).
  has_many :projects, dependent: :destroy
  has_many :monitors, through: :projects, source: :monitors
  has_many :api_keys, through: :projects

  validates :email_address, presence: true, uniqueness: { case_sensitive: false }
  validates :password, length: { minimum: 8 }, allow_nil: true

  # Keyed off verified_at so the link invalidates automatically once verified — no
  # extra column.
  generates_token_for :email_verification, expires_in: 1.week do
    verified_at
  end

  # More than a `destroy!` (see User::Closure for why the order matters).
  def close_account! = Closure.new(self).close_account!

  # Keyed off the password salt so the token self-invalidates once the password
  # changes — preventing reuse after a reset.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end
end
