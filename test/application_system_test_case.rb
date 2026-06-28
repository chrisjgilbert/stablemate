require "test_helper"
require "capybara/cuprite"

# Browser-driven system tests run headless against the Chromium that ships in the
# sandbox/CI image. We use Cuprite (Ferrum/CDP) rather than Selenium because
# Selenium Manager's chromedriver download is blocked here; Cuprite talks CDP to
# the preinstalled binary directly — no chromedriver needed. (CLAUDE.md system-test rule.)
CHROMIUM_PATH = ENV.fetch("CHROMIUM_PATH") do
  if (pw = ENV["PLAYWRIGHT_BROWSERS_PATH"]) && File.exist?(File.join(pw, "chromium"))
    File.join(pw, "chromium")
  end
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
    assert_current_path root_path
  end
end
