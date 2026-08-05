# A bearer credential for the /api/v1 surface. The raw key (sm_live_…) is shown
# to the user exactly once, at creation; only its SHA-256 digest + last 4 chars
# are persisted.
class ApiKey < ApplicationRecord
  include Authentication

  belongs_to :project
  delegate :user, to: :project, allow_nil: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_last4, presence: true

  # -> [api_key, raw_token]. The raw token is transient (never re-derivable from
  # what we store).
  def self.issue(project:, name:)
    Issuance.new(project:, name:).issue
  end

  def masked
    "sm_live_••••#{token_last4}"
  end
end
