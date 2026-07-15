require "test_helper"

# The standalone settings/api_keys screen is gone — keys are per-project now
# (Design B, projects.md §12-E/§13-S9). Only a route-level redirect remains so an
# old bookmark lands on the projects list, where keys now live. (There is no
# Settings::ApiKeysController any more; per-project coverage lives in
# test/controllers/projects/api_keys_controller_test.rb.)
class ApiKeysRedirectTest < ActionDispatch::IntegrationTest
  test "the old api-keys path redirects to the projects list" do
    sign_in users(:alice)
    get settings_api_keys_url
    assert_redirected_to "/projects"
  end
end
