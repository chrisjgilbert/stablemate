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
# NO jbuilder, despite `rails new` including it. There is not one .jbuilder
# template here — /api/v1 and the ping endpoint all `render json:` a plain Hash,
# which is the whole of our JSON surface. Removed for dependency hygiene (one
# less gem to audit, bump and cache), not for speed: it was ~4ms of boot, below
# measurement noise.

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
# accident. It backed Active Storage's image variants, and this app doesn't load
# Active Storage at all (see the note in config/application.rb), so there is
# nothing for it to back. Dropping it also took mini_magick, ruby-vips and ffi
# out of the bundle, and libvips out of the Dockerfile.
#
# Adding an attachment later means all of it together: the active_storage railtie
# in config/application.rb, a `config/storage.yml`, `active_storage.service` in
# the environment files, a volume to persist it, and
# `gem "image_processing", "~> 2.0"` plus `gem "ruby-vips", "~> 2.0"` here — both
# of them, because from 2.0 the backends are soft dependencies and Active Storage
# still requires image_processing/vips eagerly.

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
  # require: false, matching cuprite and webmock below. Bundler.require loads
  # every gem in the group at boot, but ActionDispatch::SystemTestCase and
  # cuprite both require capybara lazily — eager-loading it only taxes the unit
  # runs that never open a browser.
  gem "capybara", require: false
  # Cuprite (Ferrum/CDP) is the driver in every environment — it talks CDP to a
  # preinstalled Chromium, so there is no chromedriver to fetch. There is
  # deliberately NO selenium-webdriver; capybara loads it lazily, so restoring
  # `driven_by :selenium` is just adding the gem back.
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
