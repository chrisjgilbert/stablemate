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

  # SSL handling. By default we assume a TLS-terminating reverse proxy in front
  # (the Kamal proxy — see config/deploy.yml) and force HTTPS, so the signed
  # session cookie and the ping_token are never sent without the Secure flag
  # (no MITM session hijack). A self-hoster terminating TLS elsewhere keeps this;
  # one running plain HTTP behind their own proxy (or for a quick local trial)
  # can set STABLEMATE_FORCE_SSL=false. Defaults to ON, and a blank value
  # (STABLEMATE_FORCE_SSL=) must NOT silently disable SSL — only an explicit
  # false/0/no does (otherwise an empty env var would drop the Secure flag).
  ssl_enabled = ActiveModel::Type::Boolean.new.cast(ENV["STABLEMATE_FORCE_SSL"].presence || true)
  config.assume_ssl = ssl_enabled
  config.force_ssl  = ssl_enabled

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

  # Host used by links generated in mailer templates and absolute URLs. Links must
  # come from config, never the request (mailers have no request). (phase-4 §3.4)
  # A self-hoster sets STABLEMATE_HOST to their own domain so ping URLs and email
  # links resolve to their instance; the managed instance defaults to stablemate.dev.
  # The value may include a port (e.g. "localhost:3000") for URL building.
  app_host     = ENV["STABLEMATE_HOST"].presence || "stablemate.dev"
  app_protocol = ENV["STABLEMATE_PROTOCOL"].presence || (ssl_enabled ? "https" : "http")
  config.action_mailer.default_url_options = { host: app_host, protocol: app_protocol }
  config.action_mailer.asset_host = "#{app_protocol}://#{app_host}"

  # Restrict Host headers (DNS-rebinding protection) ONLY when the operator opts in
  # by setting STABLEMATE_HOST (or STABLEMATE_HOSTS) explicitly. We must not enable
  # host authorization off the stablemate.dev default: the managed Kamal deploy
  # leaves STABLEMATE_HOST unset and may be reached on apex/www/IP/CDN-rewritten
  # Host headers, all of which a single allow-list entry would 403. Rails strips
  # the port from the incoming Host before matching, so we add the bare host (a
  # configured "localhost:3000" must still accept a real "localhost" request).
  allowed_hosts = []
  allowed_hosts << app_host if ENV["STABLEMATE_HOST"].present?
  allowed_hosts.concat(ENV.fetch("STABLEMATE_HOSTS", "").split(",").map(&:strip).reject(&:empty?))
  unless allowed_hosts.empty?
    allowed_hosts.each { |h| config.hosts << h.split(":").first }
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end

  # Outgoing SMTP. A self-hoster wires this entirely from the environment (no
  # in-repo credentials needed). The managed Kamal instance keeps storing SMTP in
  # Rails credentials, so env takes precedence and credentials are the fallback —
  # neither path regresses. A missing address simply means mail isn't sent
  # (raise_delivery_errors is off); the install guide makes SMTP a required step
  # for down-alerts to work.
  smtp_creds = Rails.application.credentials.smtp || {}
  smtp_address = ENV["SMTP_ADDRESS"].presence || smtp_creds[:address]
  smtp_username = ENV["SMTP_USERNAME"].presence || smtp_creds[:user_name]
  smtp = {
    address: smtp_address,
    # A present-but-empty SMTP_PORT= must fall back, not crash boot via Integer("").
    # `.presence || …` covers blank, unset, and a real value.
    port: (ENV["SMTP_PORT"].presence || smtp_creds[:port] || 587).to_i,
    domain: ENV["SMTP_DOMAIN"].presence || smtp_creds[:domain],
    enable_starttls: ActiveModel::Type::Boolean.new.cast(ENV["SMTP_ENABLE_STARTTLS"].presence || true)
  }
  # Only request AUTH when a username is supplied. An unauthenticated relay (a
  # common self-host setup — a local Postfix or an internal SMTP that authorises by
  # IP) otherwise fails with "SMTP-AUTH requested but missing user name".
  if smtp_username.present?
    smtp[:user_name] = smtp_username
    smtp[:password] = ENV["SMTP_PASSWORD"].presence || smtp_creds[:password]
    smtp[:authentication] = (ENV["SMTP_AUTHENTICATION"].presence || "plain").to_sym
  end
  config.action_mailer.smtp_settings = smtp

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
