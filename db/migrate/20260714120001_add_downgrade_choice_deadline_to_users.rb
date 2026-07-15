class AddDowngradeChoiceDeadlineToUsers < ActiveRecord::Migration[8.1]
  # The involuntary-downgrade grace window (docs/specs/projects.md §7, §12-J):
  # null ⇒ not in grace. Wired up in Phase 3; the column lands now so the schema
  # is complete for the ownership cutover PR.
  def change
    add_column :users, :downgrade_choice_deadline_at, :datetime
  end
end
