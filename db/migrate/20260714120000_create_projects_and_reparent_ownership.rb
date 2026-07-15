class CreateProjectsAndReparentOwnership < ActiveRecord::Migration[8.1]
  # First-class Projects (docs/specs/projects.md §3.5).
  #
  # DEVIATION (CLAUDE.md "Deviate, but say so"): the spec's locked decision
  # (§8, §12-I) calls this "destructive — pre-launch, no production data" and
  # says to add `project_id NOT NULL` directly with no backfill. That premise
  # is false — production already has real users with monitors/api_keys rows
  # (created back when those tables were still `user_id`-scoped, see
  # 20260628144041/20260628183139), so the straight `null: false` add_reference
  # crashed production with `PG::NotNullViolation`. This migration instead
  # follows the backfill approach the spec's own adversarial review anticipated
  # for exactly this scenario (§13-B1, S1, S2): add the column nullable, backfill
  # each user's existing monitors/api_keys into a "Default" project (§13 line
  # ~354 already names this project), then enforce NOT NULL. See the errata
  # note added at docs/specs/projects.md §8.
  #
  # Written with explicit up/down (not `change`) so `db:rollback` round-trips.
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

    # Nullable first: existing monitors/api_keys predate `projects` and need a
    # project backfilled before the column can be enforced NOT NULL below.
    add_reference :monitors, :project, foreign_key: true
    add_reference :api_keys,  :project, foreign_key: true

    # Advisory metadata: the free-text `app` the gem sends on sync. A sync UPDATE
    # whose stored value differs from the incoming one flags the shared-key
    # collision the project scope otherwise can't see (§3.2, §13-B3).
    add_column :monitors, :last_synced_app, :string

    backfill_default_projects

    change_column_null :monitors, :project_id, false
    change_column_null :api_keys, :project_id, false

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

    add_reference :monitors, :user, foreign_key: true
    add_reference :api_keys,  :user, foreign_key: true

    execute <<~SQL
      UPDATE monitors SET user_id = projects.user_id
      FROM projects WHERE projects.id = monitors.project_id
    SQL
    execute <<~SQL
      UPDATE api_keys SET user_id = projects.user_id
      FROM projects WHERE projects.id = api_keys.project_id
    SQL

    change_column_null :monitors, :user_id, false
    change_column_null :api_keys, :user_id, false

    # A user can now hold the same registration_key across two different
    # projects (the exact collision the project scope fixes, §3.2) — that data
    # can't be losslessly re-homed under the old per-user unique constraint.
    # Fail with a clear message rather than a bare Postgres unique-violation.
    collision = select_value(<<~SQL)
      SELECT 1 FROM monitors
      WHERE registration_key IS NOT NULL
      GROUP BY user_id, registration_key
      HAVING COUNT(*) > 1
      LIMIT 1
    SQL
    if collision
      raise ActiveRecord::IrreversibleMigration,
        "Can't roll back: a user holds the same registration_key across multiple " \
        "projects, which the old (user_id, registration_key) unique index can't " \
        "represent. Reassign or remove the colliding monitors before rolling back."
    end

    add_index :monitors, [ :user_id, :registration_key ],
              unique: true,
              where: "registration_key IS NOT NULL",
              name: "index_monitors_on_user_and_registration_key"

    remove_column :monitors, :last_synced_app
    remove_reference :monitors, :project, foreign_key: true
    remove_reference :api_keys,  :project, foreign_key: true

    drop_table :projects
  end

  private
    # Every pre-existing user_id on monitors/api_keys moves into that user's
    # "Default" project — set-based SQL (not a per-user Ruby loop) so the
    # ACCESS EXCLUSIVE locks add_reference/change_column_null already hold on
    # these tables aren't extended by N round trips per pre-existing user
    # (projects.md §13-S1). ON CONFLICT DO NOTHING makes it retry-safe.
    def backfill_default_projects
      execute <<~SQL
        INSERT INTO projects (user_id, name, created_at, updated_at)
        SELECT DISTINCT user_id, 'Default', now(), now()
        FROM (
          SELECT user_id FROM monitors WHERE project_id IS NULL
          UNION
          SELECT user_id FROM api_keys WHERE project_id IS NULL
        ) AS legacy_owners
        ON CONFLICT (user_id, name) DO NOTHING
      SQL

      execute <<~SQL
        UPDATE monitors SET project_id = projects.id
        FROM projects
        WHERE projects.user_id = monitors.user_id
          AND projects.name = 'Default'
          AND monitors.project_id IS NULL
      SQL

      execute <<~SQL
        UPDATE api_keys SET project_id = projects.id
        FROM projects
        WHERE projects.user_id = api_keys.user_id
          AND projects.name = 'Default'
          AND api_keys.project_id IS NULL
      SQL
    end
end
