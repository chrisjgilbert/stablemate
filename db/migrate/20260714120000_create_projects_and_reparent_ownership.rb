class CreateProjectsAndReparentOwnership < ActiveRecord::Migration[8.1]
  # First-class Projects (docs/specs/projects.md §3.5). One destructive, single-
  # shot migration: the app is unlaunched, so there is no production data to
  # preserve and no backfill — monitors and API keys belong to a project from the
  # start, and `user_id` is dropped in favour of `monitor → project → user`.
  #
  # Written with explicit up/down (not `change`) so `db:rollback` round-trips
  # cleanly on an empty DB — the spec permits irreversible, but our DoD favours
  # reversible where the steps genuinely reverse (they do here).
  #
  # Ordering note: the old (user, registration_key) index must be dropped BEFORE
  # the user_id column, since Postgres auto-drops a composite index when one of its
  # columns goes — an explicit remove_index afterward would fail "does not exist".
  def up
    create_table :projects do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end
    # A user's project names are unique (the only identifier — no slug in V1).
    add_index :projects, [ :user_id, :name ], unique: true

    # Monitors + keys belong to a project from the start; user_id is gone.
    add_reference :monitors, :project, null: false, foreign_key: true
    add_reference :api_keys,  :project, null: false, foreign_key: true

    # Advisory metadata: the free-text `app` the gem sends on sync. A sync UPDATE
    # whose stored value differs from the incoming one flags the shared-key
    # collision the project scope otherwise can't see (§3.2, §13-B3).
    add_column :monitors, :last_synced_app, :string

    # Drop the old user-scoped unique index before its column, then drop user_id.
    remove_index :monitors, name: "index_monitors_on_user_and_registration_key"
    remove_reference :monitors, :user, foreign_key: true
    remove_reference :api_keys,  :user, foreign_key: true

    # The collision fix: uniqueness moves from (user, key) to (project, key), so
    # two apps under one account are two projects with independent key namespaces.
    add_index :monitors, [ :project_id, :registration_key ],
              unique: true,
              where: "registration_key IS NOT NULL",
              name: "index_monitors_on_project_and_registration_key"
  end

  def down
    remove_index :monitors, name: "index_monitors_on_project_and_registration_key"

    add_reference :monitors, :user, null: false, foreign_key: true
    add_reference :api_keys,  :user, null: false, foreign_key: true

    add_index :monitors, [ :user_id, :registration_key ],
              unique: true,
              where: "registration_key IS NOT NULL",
              name: "index_monitors_on_user_and_registration_key"

    remove_column :monitors, :last_synced_app
    remove_reference :monitors, :project, foreign_key: true
    remove_reference :api_keys,  :project, foreign_key: true

    drop_table :projects
  end
end
