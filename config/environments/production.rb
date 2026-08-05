require "active_support/core_ext/integer/time"
require "ipaddr"
# The env → config derivation, extracted so it can be tested without booting a
# production process (test/config/deployment_config_test.rb). Required here
# because environment files run before the initializer pass.
require_relative "../initializers/deployment_config"

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

  # SSL handling. By default we assume a TLS-terminating reverse proxy in front
  # (the Kamal proxy — see config/deploy.yml) and force HTTPS, so the signed
  # session cookie and the ping_token are never sent without the Secure flag
  # (no MITM session hijack). A self-hoster terminating TLS elsewhere keeps this;
  # one running plain HTTP behind their own proxy (or for a quick local trial)
  # can set STABLEMATE_FORCE_SSL=false. Defaults to ON, and a blank value
  # (STABLEMATE_FORCE_SSL=) must NOT silently disable SSL — only an explicit
  # false/0/no does (otherwise an empty env var would drop the Secure flag).
  deployment = Stablemate::DeploymentConfig.new(ENV, credentials: Rails.application.credentials.smtp || {})

  config.assume_ssl = deployment.ssl_enabled?
  config.force_ssl  = deployment.ssl_enabled?

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

  # Mail goes out over SMTP. Whether a delivery is attempted, and whether a
  # failed one is fatal, depends on SMTP actually being configured — see the
  # smtp_settings block below, which sets perform_deliveries/raise_delivery_errors.
  config.action_mailer.delivery_method = :smtp

  # Host used by links generated in mailer templates and absolute URLs. Links must
  # come from config, never the request (mailers have no request). (phase-4 §3.4)
  # A self-hoster sets STABLEMATE_HOST to their own domain so ping URLs and email
  # links resolve to their instance; the managed instance defaults to stablemate.dev.
  # The value may include a port (e.g. "localhost:3000") for URL building.
  config.action_mailer.default_url_options = { host: deployment.host, protocol: deployment.protocol }
  config.action_mailer.asset_host = deployment.asset_host

  # Restrict Host headers (DNS-rebinding protection) ONLY when the operator opts in
  # by setting STABLEMATE_HOST (or STABLEMATE_HOSTS) explicitly. We must not enable
  # host authorization off the stablemate.dev default: the managed Kamal deploy
  # leaves STABLEMATE_HOST unset and may be reached on apex/www/IP/CDN-rewritten
  # Host headers, all of which a single allow-list entry would 403. Rails strips
  # the port from the incoming Host before matching, so we add the bare host (a
  # configured "localhost:3000" must still accept a real "localhost" request).
  if deployment.host_authorization?
    deployment.allowed_hosts.each { |host| config.hosts << host }
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end

  # request.remote_ip when running behind a reverse proxy / CDN. By DEFAULT we add
  # nothing to Rails' built-in private ranges and leave ActionDispatch::RemoteIp at
  # its stock behaviour. (NB: that stock behaviour still derives remote_ip from a
  # client-supplied X-Forwarded-For — it only strips *trusted* proxy hops — so a
  # directly-exposed instance does NOT get a forgery-proof remote_ip from the
  # default. remote_ip here only feeds the coarse ping limiter + session log;
  # forgery-resistance comes from fronting the app with a proxy whose ranges are
  # trusted below, plus a firewall that blocks direct origin access.) Operators
  # behind a proxy opt in so remote_ip is the real client — without it the per-IP
  # ping rate limiter (pings_controller) collapses to a few buckets and the session
  # audit log records the proxy's address:
  #   STABLEMATE_BEHIND_CLOUDFLARE=true → also trust Cloudflare's published ranges
  #   STABLEMATE_TRUSTED_PROXIES=cidr,…  → trust arbitrary extra proxy CIDRs (an
  #                                        LB, another CDN, or to track CF's list
  #                                        without a redeploy)
  # Whatever is listed is ADDED to Rails' private ranges (which already cover the
  # kamal-proxy hop). Cloudflare ranges: https://www.cloudflare.com/ips/
  config.action_dispatch.trusted_proxies = deployment.trusted_proxies if deployment.trusted_proxies

  # Outgoing SMTP. A self-hoster wires this entirely from the environment (no
  # in-repo credentials needed). The managed Kamal instance keeps storing SMTP in
  # Rails credentials, so env takes precedence and credentials are the fallback —
  # neither path regresses. A missing address means mail isn't sent at all (see
  # the two regimes below); the install guide makes SMTP a required step for
  # down-alerts to work.
  config.action_mailer.smtp_settings = deployment.smtp_settings

  # Two deliberate regimes, keyed off whether SMTP is configured at all:
  #
  #   Configured   → deliver for real and let SMTP errors RAISE. The exception
  #     fails the ActionMailer::MailDeliveryJob, which retries with backoff
  #     (config/initializers/mail_delivery_retries.rb) and, if it still can't
  #     send, leaves a failed job an operator can see. Swallowing the error here
  #     would silently discard a down/recovered alert — i.e. the whole product —
  #     while the Notification row still claimed it was delivered.
  #   Not configured → don't attempt delivery at all, and don't raise. A
  #     self-hoster who hasn't wired SMTP yet gets no alert emails, but no
  #     perpetual failing-job storm either: there is nothing to retry against, so
  #     retrying would only burn the queue. (Alerts are lost in this state by
  #     design — the install guide makes SMTP a required step.)
  config.action_mailer.perform_deliveries    = deployment.deliver_mail?
  config.action_mailer.raise_delivery_errors = deployment.raise_delivery_errors?

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
