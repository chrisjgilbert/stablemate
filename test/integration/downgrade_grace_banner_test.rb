require "test_helper"

# The involuntary-downgrade grace banner lives in the authenticated layout, so it
# rides along on every page (projects.md §7/§12-J). It appears only while the
# account owes a choose-N decision AND the hosted tier is live — a keyless
# self-host never sees it.
class DowngradeGraceBannerTest < ActionDispatch::IntegrationTest
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze
  FREE  = Stablemate::FREE_PLAN_MONITOR_LIMIT

  setup { @user = users(:alice) }

  def enter_grace!
    @user.update!(plan: "free", awaiting_downgrade_choice: true,
      downgrade_choice_deadline_at: 5.days.from_now)
  end

  # Top the account up to `n` monitors that occupy a cap slot. Done as a Pro user,
  # since that is the only way to get over the Free cap in the first place.
  def monitors_totalling!(n)
    @user.update!(plan: "pro")
    project = @user.projects.first
    (n - @user.monitors.counting_toward_cap.count).times { |i| project.monitors.create!(name: "Extra#{i}", **ATTRS) }
  end

  test "the banner appears on the dashboard while a choice is owed" do
    with_billing_enabled do
      monitors_totalling!(FREE + 1)
      enter_grace!
      sign_in @user
      get monitors_path
      assert_select "[data-testid='downgrade-grace-banner']"
      assert_select "[data-testid='grace-choose-link']"
      assert_match "You have <strong>#{FREE + 1} monitors</strong>", response.body
      assert_match "Pick the #{FREE} to keep active", response.body
    end
  end

  # M4 — an account can be locked and yet already within the cap (a voluntary
  # choose-N downgrade racing its own cancel webhook, M3). The banner must stop
  # lying: with 3 monitors and a cap of 5 there is nothing over the cap and
  # nothing to pick.
  test "the banner stops asking for a choice once the account is within the cap" do
    with_billing_enabled do
      enter_grace! # alice's fixture monitors are well under the Free cap
      assert_equal 0, @user.over_free_cap_by
      sign_in @user
      get monitors_path

      assert_select "[data-testid='downgrade-grace-banner']"
      assert_select "[data-testid='grace-choose-link']", false
      assert_select "[data-testid='grace-review-link']"
      assert_no_match(/Pick the #{FREE} to keep active/, response.body)
      assert_match "nothing will be suspended", response.body
    end
  end

  test "no banner when the account owes no choice" do
    with_billing_enabled do
      sign_in @user
      get monitors_path
      assert_select "[data-testid='downgrade-grace-banner']", false
    end
  end

  test "no banner on a keyless self-host instance even mid-grace" do
    with_billing_disabled do
      enter_grace!
      sign_in @user
      get monitors_path
      assert_select "[data-testid='downgrade-grace-banner']", false
    end
  end
end
