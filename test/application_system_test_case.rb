require "test_helper"
require "capybara/cuprite"

# Browser-driven system tests run headless against the Chromium that ships in the
# sandbox/CI image. Cuprite (Ferrum) is the driver in every environment: it talks
# CDP straight to that binary, so there is no chromedriver to fetch and no
# Selenium Manager to depend on. (CLAUDE.md system-test rule.)
# Which binary to drive, most specific first: CHROMIUM_PATH (CI passes the one
# setup-chrome installed), the sandbox's preinstalled Chromium, then nil so
# Ferrum searches PATH. `.presence` rather than ENV.fetch's default block,
# because a workflow that sets the variable from a step output it cannot produce
# passes an EMPTY STRING — present as far as fetch is concerned, and enough to
# hand Ferrum `browser_path: ""` and fail instead of falling through.
preinstalled = File.join(ENV["PLAYWRIGHT_BROWSERS_PATH"].to_s, "chromium")
CHROMIUM_PATH = ENV["CHROMIUM_PATH"].presence || (preinstalled if File.exist?(preinstalled))

# In CI, an explicit path is not optional. The workflow pins the Chrome version it
# installs and passes that binary here; if it ever stops arriving, falling back to
# whatever Chrome the runner image happens to ship would silently void that pin —
# a green check against an unpinned browser. A pin you can't detect losing is not
# a pin.
#
# The rule lives here rather than as a shell test on one workflow step, because
# this file owns the tiers: every route into the system suite under CI inherits it,
# and a step that never reaches the suite (a docs-only run with no Gemfile) is not
# wrongly failed by it.
if ENV["CI"].present? && ENV["CHROMIUM_PATH"].blank?
  raise "CHROMIUM_PATH is not set. CI must drive the pinned browser it installed, " \
        "not whichever Chrome the runner image ships — see .github/workflows/ci.yml."
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
