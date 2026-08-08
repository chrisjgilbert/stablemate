# The check-in credential. The raw key (sm_ping_…) is shown to the user exactly
# once, at creation; only its SHA-256 digest + last 4 chars are persisted.
#
# It rides the hot path — every job completion, from every worker — and its only
# capabilities are recording a check-in and answering the no-op verify endpoint.
# It cannot read, rewrite or silence monitors; that is the API key's surface, and
# keeping the two apart is why this is a separate table rather than a `type`
# column on api_keys (v1-scope §4).
class PingKey < ApplicationRecord
  include Authentication

  belongs_to :project
  delegate :user, to: :project, allow_nil: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_last4, presence: true

  # -> [ping_key, raw_token]. The raw token is transient (never re-derivable from
  # what we store).
  def self.issue(project:, name:)
    Issuance.new(project:, name:).issue
  end

  def masked
    "sm_ping_••••#{token_last4}"
  end
end
