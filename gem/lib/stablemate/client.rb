# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Stablemate
  # HTTP client for the bearer-authed /api/v1 surface and the public ping hot path.
  # All calls use short timeouts; the ping path swallows everything (fire-and-forget).
  class Client
    include Logging

    Error = Class.new(StandardError)

    # Defence in depth — the server truncates authoritatively to the same limit.
    # Deliberately duplicated from the server's Stablemate::ERROR_MESSAGE_LIMIT:
    # the gem is standalone, so it can't share the constant; keep the two in sync.
    ERROR_MESSAGE_LIMIT = 1_000

    # http_factory: an optional callable taking a URI and returning something
    # that responds to #post / #request. The default builds a Net::HTTP with the
    # configured timeouts. It exists so a caller can supply a different transport
    # — and so the suite can assert on the request that would go on the wire
    # without patching a private method onto the instance under test.
    def initialize(config = Stablemate.config, http_factory: nil)
      @config = config
      @http_factory = http_factory
    end

    # Raises on a non-2xx / transport error so Registration#sync! can log and
    # continue.
    def sync_monitors(app:, monitors:)
      response = post_json(
        api_url("/api/v1/monitors/sync"),
        { app:, monitors: },
        headers: bearer_headers
      )
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "sync failed: #{response.code}"
      end

      JSON.parse(response.body)
    end

    # The register_on_boot = false path: load existing monitors' ping URLs
    # read-only, without upserting from recurring.yml. Raises on a non-2xx /
    # transport error so Registration can log and continue.
    def list_monitors
      response = get(api_url("/api/v1/monitors"), headers: bearer_headers)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "list failed: #{response.code}"
      end

      JSON.parse(response.body)
    end

    # Never raises — the hot path must not break the host app — but it INSPECTS the
    # response rather than assuming success:
    #   :ok    — 2xx, the ping landed;
    #   :stale — 404/410, the URL was rejected (token rotated / monitor gone), so
    #            the cached URL is dead and the caller should re-sync;
    #   :error — any other non-2xx, or a transport failure (transient — absorbed by
    #            the monitor's grace period).
    def ping(ping_url)
      uri = URI(ping_url)
      classify(http_for(uri).post(uri.request_uri, ""))
    rescue StandardError => e
      log_warn("ping failed: #{e.class}: #{e.message}")
      :error
    end

    # Reports to the SAME ping URL (no /fail suffix). Same fire-and-forget contract
    # and :ok/:stale/:error classification as #ping — never raises.
    def report_failure(ping_url, message:)
      uri = URI(ping_url)
      body = URI.encode_www_form(status: 1, message: message.to_s[0, ERROR_MESSAGE_LIMIT])
      classify(http_for(uri).post(uri.request_uri, body, "Content-Type" => "application/x-www-form-urlencoded"))
    rescue StandardError => e
      log_warn("failure report failed: #{e.class}: #{e.message}")
      :error
    end

    private
      attr_reader :config

      def classify(response)
        case response
        when Net::HTTPSuccess
          :ok
        when Net::HTTPNotFound, Net::HTTPGone
          log_warn("ping rejected #{response.code}: ping URL no longer valid (token rotated?) — re-syncing.")
          :stale
        else
          log_warn("ping rejected #{response.code}: monitor not recorded.")
          :error
        end
      end

      def api_url(path)
        URI.join(config.endpoint, path)
      end

      def bearer_headers
        { "Authorization" => "Bearer #{config.api_key}", "Content-Type" => "application/json" }
      end

      def post_json(uri, body, headers:)
        request = Net::HTTP::Post.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = JSON.generate(body)
        http_for(uri).request(request)
      end

      def get(uri, headers:)
        request = Net::HTTP::Get.new(uri)
        headers.each { |k, v| request[k] = v }
        http_for(uri).request(request)
      end

      def http_for(uri)
        return @http_factory.call(uri) if @http_factory

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = config.timeout
        http.read_timeout = config.timeout
        http
      end
  end
end
