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

  # The setup panel's one action: both credentials at once, raw values returned
  # for a single render and never stored (v1-scope §7).
  def issue_setup_pair! = SetupPair.new(self).issue_setup_pair!

  # The milestone ladder's two states. Deliberately phrased as what the project
  # is WAITING for, never as a claim that a job ran — §11 rejects the preview
  # ping precisely because a green row for a job that has never reported is the
  # one thing this product must not fake.
  # Both read the association ONCE. Spelled `monitors.load.to_a` rather than
  # `monitors.none?` / `monitors.any?`, which issue a COUNT and an EXISTS and
  # then load the rows anyway — three round trips per render, plus a second full
  # materialisation of every row, on a page that already has them in hand.
  def awaiting_first_sync? = registered_monitors.empty?

  def awaiting_first_check_in? = registered_monitors.any? && registered_monitors.none?(&:ever_pinged?)

  # Project::MonitorSync does not broadcast on its own, so newly-registered
  # monitors appeared only on reload — the user watching this page while their
  # deploy runs saw nothing happen at the exact moment it did (v1-scope §7).
  #
  # Deferred to after commit for the same reason Monitor#broadcast_status_update
  # is: Solid Queue is a SEPARATE database, so a job enqueued pre-commit can be
  # claimed by a worker that renders the project as it was before the sync, and a
  # rollback leaves an orphan job behind.
  def broadcast_setup_progress
    ActiveRecord.after_all_transactions_commit do
      broadcast_replace_later_to(
        self,
        target: ActionView::RecordIdentifier.dom_id(self, :setup_milestones),
        partial: "projects/setup_milestones",
        locals: { project: self }
      )
    end
  end

  def sync_monitors(app: nil, entries:, declared_keys: nil, prune: false)
    MonitorSync.new(self).sync_monitors(app:, entries:, declared_keys:, prune:)
  end

  private
    # `load` populates the association, so the second predicate and every
    # ever_pinged? below it read the same rows rather than going back for them.
    def registered_monitors = monitors.load.to_a
end
