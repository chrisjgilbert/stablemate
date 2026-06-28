require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy
  # (the Kamal proxy — see config/deploy.yml). Lets Rails treat proxy-terminated
  # requests as SSL so secure cookies/HSTS apply without the internal /up
  # healthcheck redirect-looping.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use
  # secure cookies — so the signed session cookie and the ping_token are never
  # sent without the Secure flag (no MITM session hijack).
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Don't blow up a request if SMTP hiccups; alerting is retried by the job layer.
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.delivery_method = :smtp

  # Host used by links generated in mailer templates. Links must come from config,
  # never the request (mailers have no request). (phase-4 §3.4)
  config.action_mailer.default_url_options = { host: "stablemate.dev", protocol: "https" }
  config.action_mailer.asset_host = "https://stablemate.dev"

  # Outgoing SMTP. Provider creds live in credentials (bin/rails credentials:edit);
  # see docs/runbook.md for the SPF/DKIM records that make this deliverable. No
  # working-looking default for the host: a missing address fails loudly at first
  # send rather than silently handing real recipient addresses to a domain we
  # don't control. STARTTLS is required, not opportunistic.
  config.action_mailer.smtp_settings = {
    address: Rails.application.credentials.dig(:smtp, :address),
    port: Rails.application.credentials.dig(:smtp, :port) || 587,
    user_name: Rails.application.credentials.dig(:smtp, :user_name),
    password: Rails.application.credentials.dig(:smtp, :password),
    authentication: :plain,
    enable_starttls: true
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
