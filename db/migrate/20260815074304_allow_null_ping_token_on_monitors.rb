# Phase 3 of the check-in cutover (v1-scope §8.1) retires `ping_token` from the
# CODE — the endpoint, the concern, the rotation controllers and the serializers
# all go — but deliberately does NOT drop the column yet.
#
# Dropping it here would break the deploy it ships in. `bin/docker-entrypoint`
# runs `db:prepare` as the NEW container boots, while the OLD container is still
# serving traffic; that old code has `ping_token` in its cached attribute list,
# so every `SELECT` against `monitors` — dashboard, sync endpoint, check-in —
# would raise `PG::UndefinedColumn` until Kamal cut traffic over. A monitoring
# product 500ing through its own deploy window is precisely the failure this
# whole redesign exists to stop causing.
#
# So this migration does the one thing the new code actually requires: the
# `PingToken` concern is gone, so nothing fills the column on insert any more,
# and a `NOT NULL` would fail every monitor `stablemate:sync` registers. Making
# it nullable is instant in Postgres and takes no lock worth naming.
#
# The DROP is a follow-up migration, applied on a LATER deploy than this code —
# by which point no running container references the column. Same for the three
# `last_synced_*` arbitration columns §3.1 orphans, which are already nullable
# and so need nothing here at all. Both sets are hidden from the app now via
# `ignored_columns` on Monitoring::Monitor.
class AllowNullPingTokenOnMonitors < ActiveRecord::Migration[8.1]
  def change
    change_column_null :monitors, :ping_token, true
  end
end
