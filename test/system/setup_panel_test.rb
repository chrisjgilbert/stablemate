require "application_system_test_case"

# Onboarding (v1-scope §7). There is no browser-only path to seeing this product
# work — the next step after signing up is genuinely "add the gem, deploy, run
# the command, wait for a job to fire" — so the panel's job is to make that wait
# legible. This is the flow a brand-new user hits immediately after creating
# their first project, which makes it the one most worth driving in a browser.
class SetupPanelTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    # carol owns no monitors, so this project is genuinely empty.
    @user = users(:carol)
    @project = @user.projects.sole
    sign_in @user
  end

  test "an empty project offers the setup command and shows both keys exactly once" do
    visit project_path(@project)

    within "[data-testid='setup-panel']" do
      # The copy-paste lines are readonly inputs, not text — the user copies
      # them with the Copy button, so their VALUE is what has to be right.
      assert_equal "bundle add stablemate", find("input[aria-label='Add the gem']").value
      assert_text "Waiting for your first sync"
      click_on "Generate setup command"
    end

    assert_selector "[data-testid='setup-command-warning']", text: "shown once"
    command = find("[data-testid='setup-panel'] input[aria-label='Setup command']").value
    assert_match(/bin\/rails stablemate:install/, command)
    assert_match(/STABLEMATE_API_KEY=sm_live_[A-Za-z0-9]{32}/, command)
    assert_match(/STABLEMATE_PING_KEY=sm_ping_[A-Za-z0-9]{32}/, command)

    # Nothing can re-display a hashed key, so a reload shows the masked form and
    # a way to start over — not the command again.
    visit project_path(@project)
    assert_no_text command
    assert_selector "[data-testid='setup-masked-note']"
    assert_text "sm_live_••••"
    assert_button "Regenerate setup command"
  end

  # Every click would otherwise mint another permanently-valid pair, and §9.4's
  # mismatch guard — which warns only when the configured key matches NO live key
  # — would stay silent by design.
  test "regenerating replaces an unused pair rather than accumulating one" do
    visit project_path(@project)
    click_on "Generate setup command"
    first = find("[data-testid='setup-panel'] input[aria-label='Setup command']").value

    visit project_path(@project)
    click_on "Regenerate setup command"
    second = find("[data-testid='setup-panel'] input[aria-label='Setup command']").value

    refute_equal first, second
    assert_equal 1, @project.api_keys.count, "an unused pair is replaced, not accumulated"
    assert_equal 1, @project.ping_keys.count
  end

  # A key already in use may be deployed somewhere; revoking it from under a
  # running install is the one thing this panel must never do. The pair has to
  # come from the panel itself — it reports only on what it issued.
  test "a key already in use survives a regenerate, and the panel says so" do
    visit project_path(@project)
    click_on "Generate setup command"
    @project.ping_keys.sole.update!(last_used_at: Time.current) # deployed somewhere

    visit project_path(@project)
    click_on "Regenerate setup command"

    assert_selector "[data-testid='setup-keys-kept']", text: "left working"
    assert_equal 2, @project.ping_keys.count
  end

  # ...and a key the panel never minted is not its to revoke at all: last_used_at
  # nil means "not used yet", which is exactly the state of a rotation key pasted
  # into secrets but not yet deployed.
  test "a key the panel never issued is left alone entirely" do
    rotation, = PingKey.issue(project: @project, name: "Rotation")

    visit project_path(@project)
    click_on "Generate setup command"

    assert PingKey.exists?(rotation.id)
  end

  # The milestone the user is actually watching. Capybara cannot set an
  # Authorization header, so the sync is driven server-side exactly as a deploy
  # would — and the panel must flip WITHOUT a reload, which is the whole reason
  # Project::MonitorSync broadcasts.
  test "the ladder flips from waiting-for-sync to registered without a reload" do
    visit project_path(@project)
    assert_text "Waiting for your first sync"

    perform_enqueued_jobs do
      @project.sync_monitors(app: "my-app", entries: [
        { registration_key: "daily_digest", name: "daily_digest",
          expected_interval_seconds: 3600, grace_period_seconds: 300 }
      ])
    end

    assert_selector "[data-testid='milestone-registered']", text: "1 monitor registered"
    assert_no_text "Waiting for your first sync"
  end

  # §11 rejects the deploy-time preview ping because a green row for a job that
  # has never reported is the lie this product exists not to tell.
  test "the panel never claims a job ran before one has" do
    @project.monitors.create!(name: "daily_digest", registration_key: "daily_digest", source: "gem",
                              expected_interval_seconds: 3600, grace_period_seconds: 300)

    visit project_path(@project)

    assert_text "waiting for first check-ins"
    assert_no_text "Checking in"
  end
end
