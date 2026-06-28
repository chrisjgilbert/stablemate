# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Stablemate
  # HTTP client for the bearer-authed /api/v1 surface and the public ping hot path.
  # All calls use short timeouts; the ping path swallows everything (fire-and-forget).
  class Client
    Error = Class.new(StandardError)

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

    # Fire-and-forget ping to a full ping URL. Best-effort: returns true/false,
    # never raises (the hot path must not break the host app). No API key here —
    # the per-monitor ping token in the URL is the only credential.
    def ping(ping_url)
      uri = URI(ping_url)
      http_for(uri).post(uri.request_uri, "")
      true
    rescue StandardError => e
      log_warn("ping failed: #{e.class}: #{e.message}")
      false
    end

    private
      attr_reader :config

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

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = config.timeout
        http.read_timeout = config.timeout
        http
      end

      def log_warn(message)
        (config.logger || Stablemate.logger).warn("[stablemate] #{message}")
      end
  end
end
