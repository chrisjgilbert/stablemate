require "test_helper"

# The involuntary-downgrade grace banner lives in the authenticated layout, so it
# rides along on every page (projects.md §7/§12-J). It appears only while the
# account owes a choose-N decision AND the hosted tier is live — a keyless
# self-host never sees it.
class DowngradeGraceBannerTest < ActionDispatch::IntegrationTest
  setup { @user = users(:alice) }

  def enter_grace!
    @user.update!(plan: "free", awaiting_downgrade_choice: true,
      downgrade_choice_deadline_at: 5.days.from_now)
  end

  test "the banner appears on the dashboard while a choice is owed" do
    with_billing_enabled do
      enter_grace!
      sign_in @user
      get monitors_path
      assert_select "[data-testid='downgrade-grace-banner']"
      assert_select "[data-testid='grace-choose-link']"
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
