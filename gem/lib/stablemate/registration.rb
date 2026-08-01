# frozen_string_literal: true

require_relative "registrars/solid_queue_recurring"

module Stablemate
  # Operation (architecture.md §9): build registration tuples from the registrar,
  # POST them to /api/v1/monitors/sync, and cache the returned ping URLs so Layer
  # 1 can map job -> URL locally. Idempotent. Runs on boot + via `rails
  # stablemate:sync`. A sync failure logs a warning and never crashes boot.
  class Registration
    include Logging

    def initialize(registrar: nil, client: nil, config: Stablemate.config, app: nil)
      @config = config
      @registrar = registrar || Registrars::SolidQueueRecurring.new(config:)
      @client = client || Client.new(config)
      @app = app || default_app_name
    end

    # Returns the { registration_key => ping_url } cache on success, or nil on
    # failure (logged, swallowed — boot continues).
    def sync!
      tuples = @registrar.tuples
      return Stablemate.ping_urls if tuples.empty?

      response = @client.sync_monitors(app: @app, monitors: tuples)
      cache_ping_urls(response)
      log_skipped(response)
      Stablemate.ping_urls
    rescue StandardError => e
      log_warn("sync failed: #{e.class}: #{e.message}")
      nil
    end

    # Read-only: load the caller's existing monitors' ping URLs (GET /monitors)
    # into the cache WITHOUT registering anything from recurring.yml. This is the
    # register_on_boot = false path — Layer 1 can still map job -> URL for monitors
    # the user manages themselves. Returns the cache on success, or nil on failure
    # (logged, swallowed — boot continues).
    def refresh_ping_urls!
      cache_ping_urls(@client.list_monitors)
      Stablemate.ping_urls
    rescue StandardError => e
      log_warn("ping-url refresh failed: #{e.class}: #{e.message}")
      nil
    end

    private
      attr_reader :config

      def cache_ping_urls(response)
        pairs = Array(response["monitors"]).each_with_object({}) do |monitor, acc|
          key = monitor["registration_key"]
          url = monitor["ping_url"]
          acc[key] = url if key && url
        end
        # Atomic fold into the shared cache (subscriber threads read concurrently).
        Stablemate.merge_ping_urls(pairs)
      end

      # The server registers what it can and returns the rest under `skipped`
      # (over the account's monitor cap, or a tuple it judged malformed). Those
      # jobs are NOT monitored — the same silent hole the registrar refuses to
      # leave when it can't size a schedule — so name each one and say why,
      # rather than dropping the list on the floor. Logged after the URL cache
      # is folded in, and defensively (a junk entry can't cost the caller its
      # ping URLs).
      def log_skipped(response)
        Array(response["skipped"]).each do |entry|
          next unless entry.is_a?(Hash)

          key = entry["registration_key"] || "(unnamed)"
          reason = entry["reason"] || "no reason given"
          log_warn("the server did not register '#{key}' (#{reason}) — that job is NOT monitored.")
        end
      end

      def default_app_name
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.class.module_parent_name.to_s.underscore
        else
          "app"
        end
      rescue StandardError
        "app"
      end
  end
end
