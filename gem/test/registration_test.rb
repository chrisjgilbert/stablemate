# frozen_string_literal: true

require_relative "test_helper"

class RegistrationTest < StablemateTest
  def registrar
    Stablemate::Registrars::SolidQueueRecurring.new(
      recurring_path: fixture("recurring.yml"), environment: "production"
    )
  end

  # Scenario 24 — sync! posts to /api/v1/monitors/sync and caches ping URLs;
  # re-running is idempotent.
  def test_sync_posts_tuples_and_caches_ping_urls
    response = {
      "monitors" => [
        { "registration_key" => "daily_digest", "ping_url" => "https://sm.test/ping/abc", "status" => "pending" },
        { "registration_key" => "clear_sessions", "ping_url" => "https://sm.test/ping/def", "status" => "pending" }
      ],
      "skipped" => []
    }
    client = Stablemate::FakeClient.new(sync_response: response)

    cache = Stablemate::Registration.new(registrar:, client:, app: "my-app").sync!

    assert_equal 1, client.synced.size
    posted = client.synced.first
    assert_equal "my-app", posted[:app]
    # The fixture's command-only db_backup task is not registered (no class: to
    # resolve pings by), so only the two class-backed tasks are posted.
    assert_equal 2, posted[:monitors].size
    assert_equal "https://sm.test/ping/abc", cache["daily_digest"]
    assert_equal "https://sm.test/ping/abc", Stablemate.ping_urls["daily_digest"]
  end

  def test_sync_is_idempotent_across_runs
    response = { "monitors" => [ { "registration_key" => "daily_digest", "ping_url" => "u" } ], "skipped" => [] }
    client = Stablemate::FakeClient.new(sync_response: response)
    reg = Stablemate::Registration.new(registrar:, client:, app: "my-app")

    reg.sync!
    reg.sync!

    assert_equal 2, client.synced.size # posts each time
    assert_equal 1, Stablemate.ping_urls.size # cache not duplicated
  end

  # F9 — the server skips entries it won't register (over the account's monitor
  # cap, or a malformed tuple). A skipped job is silently UNMONITORED, which is
  # exactly what the registrar already refuses to let happen quietly when it
  # can't size a schedule. Warn per entry, with the task key and the reason.
  def test_skipped_entries_are_logged_with_key_and_reason
    response = {
      "monitors" => [ { "registration_key" => "daily_digest", "ping_url" => "u" } ],
      "skipped" => [
        { "registration_key" => "clear_sessions", "reason" => "limit_reached" },
        { "registration_key" => "db_backup", "reason" => "invalid" }
      ]
    }
    out = StringIO.new
    client = Stablemate::FakeClient.new(sync_response: response)

    cache = Stablemate::Registration.new(registrar:, client:, app: "x", config: logging_config(out)).sync!

    assert_match(/WARN.*clear_sessions/, out.string)
    assert_match(/limit_reached/, out.string)
    assert_match(/WARN.*db_backup/, out.string)
    assert_match(/invalid/, out.string)
    # The registered monitors are still cached — reporting the skips is additive.
    assert_equal "u", cache["daily_digest"]
  end

  # No skips, no noise: a clean sync must stay silent, or the warning stops
  # meaning anything.
  def test_clean_sync_logs_nothing
    out = StringIO.new
    client = Stablemate::FakeClient.new(
      sync_response: { "monitors" => [ { "registration_key" => "daily_digest", "ping_url" => "u" } ] }
    )

    Stablemate::Registration.new(registrar:, client:, app: "x", config: logging_config(out)).sync!

    assert_empty out.string
  end

  # A malformed skipped list must not cost the caller its ping-URL cache: boot
  # continues, the URLs are still returned.
  def test_malformed_skipped_list_does_not_break_the_sync
    client = Stablemate::FakeClient.new(
      sync_response: { "monitors" => [ { "registration_key" => "daily_digest", "ping_url" => "u" } ],
                       "skipped" => [ "just-a-string", nil, {} ] }
    )

    cache = Stablemate::Registration.new(registrar:, client:, app: "x").sync!

    assert_equal "u", cache["daily_digest"]
  end

  # A sync failure logs a warning and never crashes boot (returns nil).
  def test_sync_failure_is_swallowed
    failing = Object.new
    def failing.sync_monitors(**) = raise(Stablemate::Client::Error, "boom")

    result = Stablemate::Registration.new(registrar:, client: failing, app: "x").sync!
    assert_nil result
  end

  def test_empty_registrar_does_not_post
    empty = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("missing.yml"))
    client = Stablemate::FakeClient.new
    Stablemate::Registration.new(registrar: empty, client:, app: "x").sync!
    assert_empty client.synced
  end

  # refresh_ping_urls! (the register_on_boot = false path) caches ping URLs from a
  # read-only GET /monitors WITHOUT upserting anything from recurring.yml — so
  # Layer 1 still pings monitors the user manages themselves.
  def test_refresh_caches_urls_from_list_without_posting
    list = {
      "monitors" => [
        { "registration_key" => "daily_digest", "ping_url" => "https://sm.test/ping/abc" },
        { "registration_key" => "CleanupJob",   "ping_url" => "https://sm.test/ping/xyz" }
      ]
    }
    client = Stablemate::FakeClient.new(list_response: list)

    cache = Stablemate::Registration.new(registrar:, client:).refresh_ping_urls!

    assert_empty client.synced, "refresh must not POST /monitors/sync"
    assert_equal 1, client.listed, "refresh should GET the monitor list once"
    assert_equal "https://sm.test/ping/abc", cache["daily_digest"]
    assert_equal "https://sm.test/ping/xyz", Stablemate.ping_urls["CleanupJob"]
  end

  # A failed list refresh is swallowed (returns nil) — boot never crashes.
  def test_refresh_failure_is_swallowed
    failing = Object.new
    def failing.list_monitors = raise(Stablemate::Client::Error, "boom")

    assert_nil Stablemate::Registration.new(registrar:, client: failing).refresh_ping_urls!
  end
end
