require "ipaddr"

# How a deployment's environment becomes production configuration.
#
# These are decisions, not settings: a blank STABLEMATE_FORCE_SSL must NOT drop
# the Secure flag; a blank SMTP_PORT must fall back rather than crash boot via
# Integer(""); host authorization must stay off unless the operator opts in, or
# the managed Kamal deploy starts 403-ing Host headers it used to serve. Each one
# is a rule with an edge case, and each lived inline in
# config/environments/production.rb — where the only way to reach it was to boot
# a whole production process. Given the environment as an argument instead, they
# are ordinary object behaviour: see test/config/deployment_config_test.rb.
#
# production.rb keeps the assignments and the reasoning; this keeps the
# derivation. Nothing here reads ENV or Rails on its own — pass both in — so a
# test can ask about any deployment without becoming one.
#
# Loaded in Rails' normal initializer pass and (earlier) via require_relative
# from config/environments/production.rb, which needs it before initializers run.
# Same guard as stablemate.rb, for the same reason.
return if defined?(Stablemate::DeploymentConfig)

module Stablemate
  class DeploymentConfig
    DEFAULT_HOST = "stablemate.dev".freeze
    DEFAULT_SMTP_PORT = 587
    DEFAULT_SMTP_AUTHENTICATION = "plain".freeze

    # https://www.cloudflare.com/ips/
    CLOUDFLARE_RANGES = %w[
      173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
      141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
      197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
      104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
      2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
      2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
    ].freeze

    def initialize(env = ENV, credentials: {})
      @env = env
      @credentials = credentials || {}
    end

    # Defaults ON. A present-but-empty value (STABLEMATE_FORCE_SSL= in a compose
    # file) must not read as false, or an empty variable silently drops the Secure
    # flag from the session cookie and the ping token — hence `.presence || true`
    # rather than casting the raw value.
    def ssl_enabled? = boolean(fetch("STABLEMATE_FORCE_SSL"), default: true)

    # May include a port ("localhost:3000") — this is what builds URLs.
    def host = fetch("STABLEMATE_HOST") || DEFAULT_HOST

    def protocol = fetch("STABLEMATE_PROTOCOL") || (ssl_enabled? ? "https" : "http")

    def asset_host = "#{protocol}://#{host}"

    # Only when the operator opts in by naming a host. Rails strips the port from
    # an incoming Host before matching, so a configured "localhost:3000" has to be
    # allowed as a bare "localhost" or every real request 403s.
    def allowed_hosts
      hosts = []
      hosts << host if fetch("STABLEMATE_HOST")
      hosts.concat(list("STABLEMATE_HOSTS"))
      hosts.filter_map { |entry| bare_host(entry) }
    end

    def host_authorization? = allowed_hosts.any?

    # nil means "leave ActionDispatch::RemoteIp alone". Assigning trusted_proxies
    # REPLACES Rails' defaults, so the built-in private ranges are carried along —
    # without them the kamal-proxy hop stops being stripped and remote_ip resolves
    # to the proxy rather than the client.
    def trusted_proxies
      extra = list("STABLEMATE_TRUSTED_PROXIES")
      extra += CLOUDFLARE_RANGES if boolean(fetch("STABLEMATE_BEHIND_CLOUDFLARE"), default: false)
      return nil if extra.empty?

      ActionDispatch::RemoteIp::TRUSTED_PROXIES + extra.map { |proxy| IPAddr.new(proxy) }
    end

    def smtp_address = fetch("SMTP_ADDRESS") || @credentials[:address]

    def smtp_settings
      settings = {
        address: smtp_address,
        port: (fetch("SMTP_PORT") || @credentials[:port] || DEFAULT_SMTP_PORT).to_i,
        domain: fetch("SMTP_DOMAIN") || @credentials[:domain],
        enable_starttls: boolean(fetch("SMTP_ENABLE_STARTTLS"), default: true)
      }
      username = fetch("SMTP_USERNAME") || @credentials[:user_name]
      return settings if username.blank?

      settings.merge(
        user_name: username,
        password: fetch("SMTP_PASSWORD") || @credentials[:password],
        authentication: (fetch("SMTP_AUTHENTICATION") || DEFAULT_SMTP_AUTHENTICATION).to_sym
      )
    end

    # Two deliberate regimes, both keyed off whether SMTP is configured at all.
    # Configured: deliver, and let errors raise so the delivery job retries rather
    # than silently discarding an alert while the Notification row claims it was
    # sent. Not configured: don't attempt delivery and don't raise, so a
    # self-hoster who hasn't wired SMTP gets no perpetual failing-job storm.
    def deliver_mail? = smtp_address.present?
    alias_method :raise_delivery_errors?, :deliver_mail?

    private
      # Blank is the same as unset everywhere here — an env var set to "" is how a
      # compose file or a CI step that couldn't produce a value expresses "none".
      def fetch(name) = @env[name].presence

      def list(name) = fetch(name).to_s.split(",").map(&:strip).reject(&:empty?)

      # The name Rails matches an incoming Host header against: no scheme, no
      # port. Naively splitting on the first ":" mangles anything else carrying
      # one — a scheme becomes "https", an IPv6 literal becomes "[2001" — and
      # because those are non-blank, host authorization would switch ON with an
      # allow-list nothing can match, 403-ing every request while /up stays
      # excluded and the health check reports green. nil for an entry with no
      # host left in it, so it is dropped rather than becoming a dead rule.
      def bare_host(entry)
        without_scheme = entry.sub(%r{\A[a-z][a-z0-9+.\-]*://}i, "")
        # An IPv6 literal is bracketed precisely so its colons aren't a port.
        return Regexp.last_match(0) if without_scheme.match(/\A\[[^\]]+\]/)

        without_scheme.split(":").first.presence
      end

      def boolean(value, default:)
        ActiveModel::Type::Boolean.new.cast(value.nil? ? default : value)
      end
  end
end
