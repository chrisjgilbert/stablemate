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

    # Client-side bound on a reported error message (defence in depth — the
    # server truncates authoritatively to the same limit).
    ERROR_MESSAGE_LIMIT = 1_000

    def initialize(config = Stablemate.config)
      @config = config
    end

    # POST /api/v1/monitors/sync with bearer auth. Returns the parsed response
    # hash ({"monitors" => [...], "skipped" => [...]}). Raises on a non-2xx /
    # transport error so Registration#sync! can log and continue.
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

    # GET /api/v1/monitors with bearer auth. Returns the parsed response hash
    # ({"monitors" => [...]}). Used by the register_on_boot = false path to load
    # existing monitors' ping URLs read-only, without upserting from recurring.yml.
    # Raises on a non-2xx / transport error so Registration can log and continue.
    def list_monitors
      response = get(api_url("/api/v1/monitors"), headers: bearer_headers)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "list failed: #{response.code}"
      end

      JSON.parse(response.body)
    end

    # Fire-and-forget ping to a full ping URL. Best-effort and never raises (the
    # hot path must not break the host app), but it INSPECTS the response instead
    # of assuming success — a 404/429/5xx used to be reported as a delivered ping,
    # so a rotated token or a throttled loop silently produced false DOWN alerts.
    # Returns a status the caller can act on:
    #   :ok    — 2xx, the ping landed;
    #   :stale — 404/410, the URL was rejected (token rotated / monitor gone), so
    #            the cached URL is dead and the caller should re-sync;
    #   :error — any other non-2xx, or a transport failure (transient — absorbed
    #            by the monitor's grace period).
    def ping(ping_url)
      uri = URI(ping_url)
      classify(http_for(uri).post(uri.request_uri, ""))
    rescue StandardError => e
      log_warn("ping failed: #{e.class}: #{e.message}")
      :error
    end

    # Report a terminal job failure to the SAME ping URL (no /fail suffix):
    # form-encoded status=1&message=…, message truncated to ERROR_MESSAGE_LIMIT.
    # Same fire-and-forget contract and :ok/:stale/:error classification as
    # #ping — never raises.
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
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = config.timeout
        http.read_timeout = config.timeout
        http
      end
  end
end
