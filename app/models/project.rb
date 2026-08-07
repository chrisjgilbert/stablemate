# A first-class grouping of monitors under a user. Ownership flows
# `monitor → project → user`, so the monitor cap and billing stay per-user while
# identity and the gem `registration_key` namespace are per-project.
class Project < ApplicationRecord
  belongs_to :user
  has_many :monitors, class_name: "Monitoring::Monitor", dependent: :destroy
  has_many :api_keys, dependent: :destroy
  # A project may hold several live ping keys at once — that is what makes
  # rotation possible without a gap (v1-scope §4).
  has_many :ping_keys, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :user_id }

  def sync_monitors(app: nil, entries:)
    MonitorSync.new(self).sync_monitors(app:, entries:)
  end
end
