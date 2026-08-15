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
# The new code needs the column to stop being `NOT NULL`, because the
# `PingToken` concern that filled it on insert is deleted. But relaxing the
# constraint is not enough on its own, and the near-miss is worth spelling out:
# during that same overlap window a `stablemate:sync` served by the NEW
# container would insert a monitor with `ping_token = NULL`, and the OLD
# container then renders that row through `ping_url(monitor.ping_token)` —
# `ping_url(nil)` raises `ActionController::UrlGenerationError`, so the
# dashboard and the whole `/api/v1/monitors` index 500 on one bad row. Exactly
# the outage this migration exists to avoid, arriving through the other door.
#
# So the column also gets a DATABASE-side default. The new code omits
# `ping_token` from its INSERTs entirely (it is in `ignored_columns`), which is
# precisely when Postgres applies a default — so rows created during the window
# still carry a usable token for the old container to render, and no Ruby in
# this codebase has to know the column exists. 32 hex chars, matching the shape
# the deleted `PingToken::TOKEN_LENGTH` generated.
#
# Both the default and the column are removed by the follow-up migration, on a
# LATER deploy than this code — by which point no running container references
# either. The three `last_synced_*` arbitration columns §3.1 orphans are already
# nullable and were never generated, so they need nothing here.
class AllowNullPingTokenOnMonitors < ActiveRecord::Migration[8.1]
  def up
    change_column_null :monitors, :ping_token, true
    # gen_random_uuid() is core Postgres since 13 (production runs 16), so this
    # needs no extension. Unique per row, which the column's unique index
    # requires.
    change_column_default :monitors, :ping_token,
                          from: nil, to: -> { "replace(gen_random_uuid()::text, '-', '')" }
  end

  def down
    change_column_default :monitors, :ping_token,
                          from: -> { "replace(gen_random_uuid()::text, '-', '')" }, to: nil
    change_column_null :monitors, :ping_token, false
  end
end
