# A first-class grouping of monitors under a user (docs/specs/projects.md §4.1).
# A user has many projects; a project owns its monitors and the API keys that
# authenticate the gem for that app. Ownership flows `monitor → project → user`,
# so the monitor cap and billing stay per-user (§7) while identity and the gem
# `registration_key` namespace become per-project — the collision fix (§1).
class Project < ApplicationRecord
  belongs_to :user
  has_many :monitors, class_name: "Monitoring::Monitor", dependent: :destroy
  has_many :api_keys, dependent: :destroy

  # `name` is the only identifier (no slug in V1, §3.1) and is unique per user.
  validates :name, presence: true, uniqueness: { scope: :user_id }

  # Idempotent bulk upsert of monitors from the gem's sync payload. Delegates to
  # the entity-scoped operation object; `app` is the free-text app string the gem
  # sends (recorded as advisory `last_synced_app`, §3.2).
  def sync_monitors(app: nil, entries:)
    MonitorSync.new(self).sync_monitors(app:, entries:)
  end
end
