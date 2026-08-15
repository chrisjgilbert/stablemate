require "test_helper"

# The setup panel's one action (v1-scope §7): issue BOTH credentials, render the
# install line once, and never accumulate live pairs behind the user's back.
class Projects::SetupCommandsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:carol) # owns no monitors, so the ladder states are this file's
    @project = @user.projects.sole
    sign_in @user
  end

  def generate = post(project_setup_command_path(@project))

  # Issuing only the API key would seed a project that can register monitors and
  # never check one in — the permanently-grey-row failure §7 exists to prevent.
  test "generating issues both credentials and shows both exactly once" do
    assert_difference [ -> { @project.api_keys.count }, -> { @project.ping_keys.count } ], 1 do
      generate
    end
    assert_response :created

    assert_match(/sm_live_[A-Za-z0-9]{32}/, response.body)
    assert_match(/sm_ping_[A-Za-z0-9]{32}/, response.body)
    assert_match(/bin\/rails stablemate:install/, response.body)
  end

  test "a reload shows the command masked, never the raw keys" do
    generate
    raw_api = response.body[/sm_live_[A-Za-z0-9]{32}/]
    raw_ping = response.body[/sm_ping_[A-Za-z0-9]{32}/]

    get project_path(@project)
    assert_response :success
    assert_no_match(/#{Regexp.escape(raw_api)}/, response.body)
    assert_no_match(/#{Regexp.escape(raw_ping)}/, response.body)
    assert_match(/sm_live_••••#{raw_api.last(4)}/, response.body)
    assert_select "[data-testid='setup-masked-note']"
  end

  # Without this, every click mints another permanently-valid pair and §9.4's
  # mismatch guard — which warns only when the configured key matches NO live
  # key — stays silent by design while the project accumulates credentials
  # nobody is tracking.
  test "regenerating revokes the unused pair it supersedes" do
    generate
    first_api = @project.api_keys.sole
    first_ping = @project.ping_keys.sole

    assert_no_difference [ -> { @project.api_keys.count }, -> { @project.ping_keys.count } ] do
      generate
    end
    assert_not ApiKey.exists?(first_api.id)
    assert_not PingKey.exists?(first_ping.id)
  end

  # A key that has been used may be deployed somewhere. Revoking it here would
  # take a working install offline — the one thing this panel must never do —
  # and at that point the user is in §4's add-before-remove rotation anyway.
  test "regenerating leaves a key that has already been used alive, and says so" do
    generate
    used = @project.ping_keys.sole
    used.update!(last_used_at: Time.current)

    generate

    assert PingKey.exists?(used.id), "a key in use must survive a regenerate"
    assert_equal 2, @project.ping_keys.count
    assert_select "[data-testid='setup-keys-kept']"
  end

  # The panel is hidden once a project is live, and a check-in can land between
  # the page load and the click. Without the setup_pair branch in the view, the
  # response that carries the ONLY readable copy of both keys omits the panel —
  # after the superseded pair has already been destroyed. Live credentials that
  # nobody has ever seen.
  test "the command renders even if the project goes live between load and click" do
    monitor = @project.monitors.create!(name: "daily_digest", registration_key: "daily_digest",
                                        source: "gem", expected_interval_seconds: 3600,
                                        grace_period_seconds: 300)
    monitor.check_in! # the project is no longer waiting for anything
    assert_not @project.awaiting_first_sync?
    assert_not @project.awaiting_first_check_in?

    generate

    assert_response :created
    assert_match(/sm_live_[A-Za-z0-9]{32}/, response.body)
    assert_match(/sm_ping_[A-Za-z0-9]{32}/, response.body)
  end

  # last_used_at nil means "not used YET", never "safe to delete": a key minted
  # for §4's rotation, or pasted into .kamal/secrets before a deploy, is unused
  # and must survive.
  test "regenerating leaves keys this panel did not issue alone" do
    rotation, = PingKey.issue(project: @project, name: "Rotation")
    generate

    assert PingKey.exists?(rotation.id), "a key the setup panel never issued is not its to revoke"
  end

  test "cannot generate a setup command for another user's project" do
    bobs = users(:bob).projects.sole
    assert_no_difference -> { ApiKey.count } do
      post project_setup_command_path(bobs)
    end
    assert_response :not_found
  end

  # --- The milestone ladder (§7) ---------------------------------------------

  test "the ladder waits for the first sync, then for the first check-in" do
    get project_path(@project)
    assert_select "[data-testid='setup-milestones']", /Waiting for your first sync/

    monitor = @project.monitors.create!(name: "daily_digest", registration_key: "daily_digest",
                                        source: "gem", expected_interval_seconds: 3600,
                                        grace_period_seconds: 300)
    get project_path(@project)
    assert_select "[data-testid='milestone-registered']", /1 monitor registered/

    # Once the project is live the panel has done its job and goes away —
    # §7 specifies two waiting states, not a permanent banner.
    monitor.check_in!
    get project_path(@project)
    assert_select "[data-testid='setup-panel']", false
  end

  # §11 rejects the deploy-time preview ping because a green row for a job that
  # has never reported is the lie this product exists not to tell. The ladder
  # must not tell it either.
  test "the ladder never claims a job ran before one has" do
    @project.monitors.create!(name: "daily_digest", registration_key: "daily_digest", source: "gem",
                              expected_interval_seconds: 3600, grace_period_seconds: 300)

    get project_path(@project)

    assert_select "[data-testid='milestone-checked-in']", false
    assert_no_match(/checking in/i, css_select("[data-testid='setup-milestones']").to_s)
  end

  # The panel is what the user is looking at while their deploy runs, so the
  # sync has to tell it — otherwise the flip happens only on a manual reload.
  test "a sync that registers monitors broadcasts the ladder" do
    get project_path(@project) # subscribes

    assert_enqueued_jobs 1, only: Turbo::Streams::ActionBroadcastJob do
      @project.sync_monitors(app: "my-app", entries: [
        { registration_key: "daily_digest", name: "daily_digest",
          expected_interval_seconds: 3600, grace_period_seconds: 300 }
      ])
    end
  end

  test "a sync that registers nothing new says nothing" do
    assert_no_enqueued_jobs only: Turbo::Streams::ActionBroadcastJob do
      @project.sync_monitors(app: "my-app", entries: [])
    end
  end
end
