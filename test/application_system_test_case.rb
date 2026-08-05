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

# In CI the path is not optional: the workflow installs a pinned Chrome and passes
# it here, and falling back to whatever the runner image ships would mean a green
# check against an unpinned browser.
if ENV["CI"].present? && ENV["CHROMIUM_PATH"].blank?
  raise "CHROMIUM_PATH is not set. CI must drive the pinned browser it installed, " \
        "not whichever Chrome the runner image ships — see .github/workflows/ci.yml."
end

# Capybara's stock 2s. A page that renders in 200ms locally can exceed that on a
# loaded CI box or a shared runner, and a waiting assertion that gives up early
# fails a test the code did nothing wrong in. 5s costs nothing when things are
# fast — waiting assertions return as soon as the condition holds — and only
# spends the extra when the machine is busy, which is exactly when it should.
#
# NB this does NOT paper over a stale-element race: holding a node reference
# across a Turbo re-render raises ObsoleteNode however long the window is. Those
# have to be re-found instead — see the plan cards in pricing_page_test.
# `.presence`, not ENV.fetch's default: a workflow that sets this from a step
# output it could not produce passes an EMPTY STRING, which fetch treats as
# present and Float() then rejects — killing the whole suite at file load rather
# than falling back. Exactly the hazard CHROMIUM_PATH guards against above.
Capybara.default_max_wait_time = Float(ENV["CAPYBARA_MAX_WAIT_TIME"].presence || 5)

# Let `fill_in` / `select` find a control by its aria-label. Several controls
# here are labelled that way (the interval and grace presets), and without this
# a test has to reach for `find("select[aria-label=…]").select(…)` — which
# captures a node and then acts on it, the shape that goes stale across a
# re-render. Asking for the ACCESSIBLE NAME is both the sturdier selector and
# the more honest description of what the user is looking at.
Capybara.enable_aria_label = true

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
