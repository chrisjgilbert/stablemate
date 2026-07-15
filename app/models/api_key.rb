# A bearer credential for the /api/v1 surface. The raw key (sm_live_…) is shown
# to the user exactly once, at creation; only its SHA-256 digest + last 4 chars
# are persisted (the masked UI form). Thin manifest of includes — the behaviour
# lives in the issuance operation and the authentication concern (architecture.md §4).
class ApiKey < ApplicationRecord
  include Authentication

  belongs_to :project
  # Design B (docs/specs/projects.md §3.4): a key belongs to one project and IS
  # that app's identity. `user` delegates through the project so owner-scoped
  # checks keep working; allow_nil mirrors the monitor delegate.
  delegate :user, to: :project, allow_nil: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_last4, presence: true

  # Issue a new key for a project: ApiKey.issue(project:, name:) -> [api_key,
  # raw_token]. The raw token is transient (never re-derivable from what we store).
  def self.issue(project:, name:)
    Issuance.new(project:, name:).issue
  end

  # The masked form shown in the UI: sm_live_••••<last4>. Never reveals the key.
  def masked
    "sm_live_••••#{token_last4}"
  end
end
