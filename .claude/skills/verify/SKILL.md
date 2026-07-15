---
name: verify
description: Launch Stablemate and drive it in a real headless browser to observe a change working, beyond what the test suite proves.
---

# Verifying Stablemate

Rails 8, server-rendered Hotwire app. No JS build step to worry about beyond
Tailwind (already wired into `bin/rails server`/`bin/dev`).

## Launch

Don't collide with the app's own dev server (port 3000) or a running test
suite. Use a scratch port:

```sh
(RAILS_ENV=development PORT=3100 bin/rails server -p 3100 -b 0.0.0.0 \
  > /tmp/rails_verify_server.log 2>&1 &)
sleep 6
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3100/   # sanity check
```

The dev DB is already seeded by the SessionStart hook (demo user, one
monitor). `RAILS_ENV=development` picks up `.env`/dev credentials; no Stripe
keys are configured by default, so `Stablemate.billing_enabled?` is false —
this is the **self-host** posture. To verify a billing-enabled flow, either
drive it through the Capybara `with_billing_enabled` system-test path (it
stubs `Stablemate.billing_enabled?` and the Stripe keys in-process — see
`test/test_helper.rb`) or set real `STRIPE_*` credentials before booting.

Kill it when done: `pkill -f "rails server -p 3100"` (or find the `puma`
process by port and `kill` it directly — `pkill -f` sometimes only kills the
wrapping shell, not the forked puma process).

## Drive it

- **Raw HTML / routing / copy checks** — `curl` the path, `grep` the
  response body. Fast, good for confirming interpolated values (plan
  limits, retention days) actually rendered.
- **Rendered / visual checks** — headless Chromium via Ferrum directly
  (the same binary the Capybara/Cuprite system tests use, found at
  `ENV["PLAYWRIGHT_BROWSERS_PATH"]/chromium`). No need for the full
  Capybara/Rails-test harness just to look at a page:

  ```ruby
  require "ferrum"
  chromium_path = File.join(ENV["PLAYWRIGHT_BROWSERS_PATH"], "chromium")
  browser = Ferrum::Browser.new(
    headless: true, browser_path: chromium_path,
    browser_options: { "no-sandbox" => nil, "disable-gpu" => nil },
    window_size: [1400, 1400], process_timeout: 30, timeout: 30
  )
  browser.goto("http://localhost:3100/pricing")
  sleep 1
  browser.screenshot(path: "/tmp/.../out.png", full: true)  # full page
  browser.quit
  ```

  For mobile, set `window_size: [390, 844]`. To click through a flow
  (`browser.at_xpath("//a[text()='Pricing']").click`), then
  `browser.current_url` confirms navigation.

- **`full: true` on `screenshot`** — without it you get just the current
  viewport, and a `window.scrollTo` before capture is fragile (it's easy to
  scroll past the end of a shorter page into blank space below the
  content, especially before fonts/layout settle). Prefer a full-page
  capture and crop mentally, or `sleep 1.5`+ before scrolling to let
  Google Fonts / layout settle first.

## Gotchas

- The marketing pages (`/`, `/pricing`) load Google Fonts over the network
  in `layouts/landing.html.erb` — outbound HTTPS goes through the sandbox's
  proxy, so first paint can be slow. `sleep 1`–`2` after `goto` before
  screenshotting.
- `pkill -f "rails server -p PORT"` doesn't always reach the forked `puma`
  process — check `ps aux | grep PORT` afterward and `kill` the PID
  directly if it's still listed.
