source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Tailwind CSS, the project's styling framework [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# NO image_processing, despite `rails new` putting it here — deliberate, and the
# line is absent rather than commented so nobody has to wonder whether it was an
# accident. Nothing in this app declares an attachment (no has_one_attached, no
# has_many_attached, and active_storage:install was never run — the schema has no
# active_storage_* tables), so it processed exactly zero variants.
#
# Dependabot proposed 1.2 → 2.0 (#6), which forced the question. From 2.0 the
# backends are soft dependencies, but Active Storage's transformers/vips.rb still
# requires image_processing/vips eagerly at boot whenever the gem is present and
# variant_processor is :vips (the default under load_defaults 7.0+). Its rescue
# only recognises LoadErrors naming `libvips` or `image_processing`, and 2.0's
# message names neither — so the bump alone doesn't boot, it needs ruby-vips too.
#
# So the bump is "add a second gem to keep an unused one working". Dropping it
# instead takes four gems out of the bundle — image_processing, mini_magick,
# ruby-vips and ffi, the last two a native extension needing libvips on every
# machine that runs this app, self-hosters included. libvips leaves the
# Dockerfile with them.
#
# Absent, the gem's LoadError DOES match Active Storage's rescue, so the app
# boots — but it warns "Generating image variants require the image_processing
# gem…" on every boot, in every environment, which self-hosters would read in
# their own production log. config/application.rb answers that by declaring
# `variant_processor = :disabled`, the escape hatch that warning itself names.
# The two belong together: restoring either without the other is a bug.
#
# Add `gem "image_processing", "~> 2.0"` and `gem "ruby-vips", "~> 2.0"` back —
# and drop the :disabled line — the day something here needs a variant.

# Hosted-tier billing (issue #19, hosted-only / config-gated). Pay wraps Stripe
# subscription state via the pay_* tables — we don't hand-roll it. Dormant unless
# Stripe keys are configured. [https://github.com/pay-rails/pay]
gem "pay", "~> 11.6"
gem "stripe", "~> 19.3"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  # Kept, though nothing currently drives it — CLAUDE.md names
  # `driven_by :selenium, using: :headless_chrome` as the preferred driver, with
  # Cuprite below as the sandbox fallback, so this is stated intent rather than
  # leftover scaffolding. (Which is why it is bumped and image_processing above
  # was dropped: same "unused", different reason for being here.) Revisit if the
  # Cuprite fallback ever becomes the documented default.
  gem "selenium-webdriver"
  # Cuprite (Ferrum/CDP) drives the preinstalled Chromium directly when Selenium
  # Manager's chromedriver download is blocked in the sandbox.
  gem "cuprite", require: false
  # Block real outbound HTTP in the suite (localhost stays open for Capybara/
  # Puma/Cuprite). Stripe paths are exercised end-to-end against stubbed
  # api.stripe.com responses, never the live API.
  gem "webmock", require: false
end

gem "honeybadger", "~> 6.9"

gem "letter_opener", "~> 1.10", group: :development

# Catches unsafe migrations before they run [https://github.com/ankane/strong_migrations]
gem "strong_migrations"
