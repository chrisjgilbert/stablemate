# A bearer credential for the /api/v1 surface. The raw key (sm_live_…) is shown
# to the user exactly once, at creation; only its SHA-256 digest + last 4 chars
# are persisted (the masked UI form). Thin manifest of includes — the behaviour
# lives in the issuance operation and the authentication concern (architecture.md §4).
class ApiKey < ApplicationRecord
  include Authentication

  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_last4, presence: true

  # Issue a new key for a user: ApiKey.issue(user:, name:) -> [api_key, raw_token].
  # The raw token is transient (never re-derivable from what we store).
  def self.issue(user:, name:)
    Issuance.new(user:, name:).issue
  end

  # The masked form shown in the UI: sm_live_••••<last4>. Never reveals the key.
  def masked
    "sm_live_••••#{token_last4}"
  end
end
