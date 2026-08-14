require "test_helper"

class Api::V1::Monitors::SyncsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:bob) # owns one fixture monitor
    @project = @user.projects.sole
    _key, @raw = ApiKey.issue(project: @project, name: "CI")
  end

  def auth = { "Authorization" => "Bearer #{@raw}" }

  def sync(monitors)
    post sync_api_v1_monitors_url, params: { app: "my-app", monitors: }, as: :json, headers: auth
  end

  def entry(key, name: nil, interval: 3600, grace: 300)
    { registration_key: key, name: name || key,
      expected_interval_seconds: interval, grace_period_seconds: grace }
  end

  test "new registration keys create gem/pending monitors and return ping_url" do
    sync([ entry("daily_digest") ])
    assert_response :success

    body = JSON.parse(response.body)
    entry = body["monitors"].first
    assert_equal "daily_digest", entry["registration_key"]
    assert_equal "pending", entry["status"]
    assert_includes entry["ping_url"], "/ping/"

    monitor = @user.monitors.find_by(registration_key: "daily_digest")
    assert_equal "gem", monitor.source
  end

  test "re-syncing updates and does not duplicate" do
    sync([ entry("daily_digest", name: "First", interval: 3600) ])
    assert_no_difference -> { @user.monitors.count } do
      sync([ entry("daily_digest", name: "Renamed", interval: 7200) ])
    end
    monitor = @user.monitors.find_by(registration_key: "daily_digest")
    assert_equal "Renamed", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
  end

  test "cap overflow registers up to the cap and skips the rest with 200" do
    sync(%w[a b c d e f].map { |k| entry(k) })
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 4, body["monitors"].size
    assert_equal 2, body["skipped"].size
    assert_equal "limit_reached", body["skipped"].first["reason"]
  end

  test "updates to existing monitors succeed at the cap" do
    sync((1..4).map { |i| entry("k#{i}") }) # bob now at 5 (1 fixture + 4)
    sync([ entry("k1", name: "Updated") ])
    assert_response :success
    assert_empty JSON.parse(response.body)["skipped"]
    assert_equal "Updated", @user.monitors.find_by(registration_key: "k1").name
  end

  test "monitors absent from the payload are left untouched" do
    sync([ entry("keep") ])
    before = @user.monitors.count
    sync([ entry("other") ])
    assert_equal before + 1, @user.monitors.count
    assert @user.monitors.exists?(registration_key: "keep")
  end

  test "the returned ping_url records a PingEvent when hit" do
    sync([ entry("daily_digest") ])
    url = JSON.parse(response.body)["monitors"].first["ping_url"]
    monitor = @user.monitors.find_by(registration_key: "daily_digest")

    assert_difference -> { monitor.ping_events.count }, 1 do
      post URI(url).path
    end
    assert_response :success
    assert_equal "up", monitor.reload.status
  end

  # Caps OFF (issue #16): the gem sync never returns skipped: limit_reached when no
  # cap is configured — all well-formed new keys register.
  test "with the cap OFF, sync registers every key and skips nothing for limit" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      sync(%w[a b c d e f].map { |k| entry(k) })
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 6, body["monitors"].size
      assert_empty body["skipped"]
    end
  end

  test "sync requires a bearer token" do
    post sync_api_v1_monitors_url, params: { monitors: [] }, as: :json
    assert_response :unauthorized
  end

  # projects.md §9 (Design B) — sync upserts into the KEY's project. The same
  # registration_key already existing in ANOTHER project of the same user does not
  # collide (the collision fix) and is left untouched.
  test "sync upserts into the key's project and does not touch a same-key monitor in another project" do
    other = @user.projects.create!(name: "Other app")
    other_monitor = other.monitors.create!(
      name: "Other daily_digest", registration_key: "daily_digest", source: "gem", status: "pending",
      expected_interval_seconds: 3600, grace_period_seconds: 300
    )

    sync([ entry("daily_digest", name: "Mine") ])
    assert_response :success

    mine = @project.monitors.find_by(registration_key: "daily_digest")
    assert_equal "Mine", mine.name
    refute_equal other_monitor.id, mine.id
    assert_equal "Other daily_digest", other_monitor.reload.name # untouched
  end

  # --- Prune, over the wire (v1-scope §6.1, §11) -----------------------------

  # The whole of phase 1 is inert until a 0.2.0 gem sends the new fields. A
  # pre-0.2.0 payload sends neither, so it must write exactly what it writes
  # today — the envelope gains two informational keys and nothing else moves.
  test "a legacy payload registers as it always did and retires nothing" do
    sync([ entry("daily_digest"), entry("nightly_backup") ])

    assert_no_changes -> { @user.monitors.pluck(:status).sort } do
      sync([ entry("daily_digest") ])
    end
    assert_response :success

    body = response.parsed_body
    assert_equal [ "daily_digest" ], body["monitors"].map { |m| m["registration_key"] }
    assert_equal [ "nightly_backup" ], body["orphaned"]
    assert_empty body["retired"]
  end

  test "prune with declared_keys retires the absent task and names it in the envelope" do
    sync([ entry("daily_digest"), entry("nightly_backup") ])

    post sync_api_v1_monitors_url, as: :json, headers: auth,
         params: { app: "my-app", prune: true, declared_keys: %w[daily_digest],
                   monitors: [ entry("daily_digest") ] }

    assert_response :success
    assert_equal [ "nightly_backup" ], response.parsed_body["retired"]
    assert_empty response.parsed_body["orphaned"]
    assert_equal "retired", @user.monitors.find_by(registration_key: "nightly_backup").status
  end

  # The gem sends the check-in form-encoded, and a rake task's flag arrives as a
  # string — "1" has to mean the same thing as JSON's `true`.
  test "the prune flag is honoured form-encoded as well as in JSON" do
    sync([ entry("daily_digest"), entry("nightly_backup") ])

    post sync_api_v1_monitors_url, headers: auth,
         params: { app: "my-app", prune: "1", declared_keys: %w[daily_digest],
                   monitors: [ entry("daily_digest") ] }

    assert_response :success
    assert_equal [ "nightly_backup" ], response.parsed_body["retired"]
  end

  test "a prune flag with no declared_keys retires nothing" do
    sync([ entry("daily_digest"), entry("nightly_backup") ])

    post sync_api_v1_monitors_url, as: :json, headers: auth,
         params: { app: "my-app", prune: true, monitors: [ entry("daily_digest") ] }

    assert_response :success
    assert_empty response.parsed_body["retired"]
    assert_equal "pending", @user.monitors.find_by(registration_key: "nightly_backup").status
  end

  test "the schedule string rides the wire and is stored" do
    post sync_api_v1_monitors_url, as: :json, headers: auth,
         params: { app: "my-app",
                   monitors: [ entry("reports.daily").merge(schedule: "0 9 * * 1-5") ] }

    assert_response :success
    assert_equal "0 9 * * 1-5", @user.monitors.find_by(registration_key: "reports.daily").schedule
  end
end
