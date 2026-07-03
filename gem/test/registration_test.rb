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
end
