require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  # The marketing landing page is the public root for anonymous visitors.
  test "anonymous visitors see the marketing landing page at the root" do
    get root_path
    assert_response :success
    assert_select "h1"
    assert_select "a[href=?]", sign_up_path
  end

  # Signed-in users don't see marketing — the root takes them to their dashboard.
  test "signed-in users are sent from the root to their dashboard" do
    sign_in users(:alice)
    get root_path
    assert_redirected_to monitors_path
  end

  # No pricing/tier/upgrade UI anywhere on the landing page (one Free plan).
  test "the landing page has no pricing or upgrade UI" do
    get root_path
    assert_no_match(/pricing|upgrade|\$\d|per month|\/mo\b/i, response.body)
  end
end
