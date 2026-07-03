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
      Stablemate.ping_urls
    rescue StandardError => e
      log_warn("sync failed: #{e.class}: #{e.message}")
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
