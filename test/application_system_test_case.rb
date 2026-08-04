require "test_helper"
require "capybara/cuprite"

# Browser-driven system tests run headless against the Chromium that ships in the
# sandbox/CI image. We use Cuprite (Ferrum/CDP) rather than Selenium because
# Selenium Manager's chromedriver download is blocked here; Cuprite talks CDP to
# the preinstalled binary directly — no chromedriver needed. (CLAUDE.md system-test rule.)
# Three tiers, most specific first: an explicit CHROMIUM_PATH (CI hands over the
# binary setup-chrome installed), then the sandbox's preinstalled Chromium, then
# nil — which lets Ferrum find Chrome on PATH itself.
#
# .presence, not ENV.fetch's default block: a workflow that sets the variable
# from a step output it cannot produce passes an EMPTY STRING, and an empty
# string is present as far as fetch is concerned. That would hand Ferrum
# browser_path: "" and fail, instead of falling through to the tiers below.
CHROMIUM_PATH = ENV["CHROMIUM_PATH"].presence || begin
  preinstalled = ENV["PLAYWRIGHT_BROWSERS_PATH"].presence&.then { |dir| File.join(dir, "chromium") }
  preinstalled if preinstalled && File.exist?(preinstalled)
end

Capybara.register_driver(:stablemate_cuprite) do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [ 1400, 1400 ],
    headless: true,
    browser_path: CHROMIUM_PATH,
    # Flags needed to run Chromium as root in a sandboxed container.
    browser_options: { "no-sandbox" => nil, "disable-gpu" => nil },
    process_timeout: 30,
    timeout: 30
  )
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include ActionView::RecordIdentifier # dom_id in assertions

  driven_by :stablemate_cuprite

  # Sign in through the real rendered UI (system tests must not fake the session).
  # Fixtures share the password "password1234".
  def sign_in(user, password: "password1234")
    visit sign_in_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: password
    click_on "Sign in"
    # Post-login lands on the dashboard: auth sends you to root, and the root
    # redirects signed-in users on to /monitors (phase-4 landing page).
    assert_current_path monitors_path
  end
end
