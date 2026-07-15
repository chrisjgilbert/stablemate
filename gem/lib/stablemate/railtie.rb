# frozen_string_literal: true

require "rails/railtie"

module Stablemate
  # Wires the gem into a host Rails app with zero per-job code:
  # - on boot: sync monitors from config/recurring.yml and attach the execution
  #   subscriber (so successful recurring runs ping automatically).
  # - registers the `stablemate:sync` rake task.
  #
  # Boot must never be blocked or crashed by Stablemate: Registration#sync! and
  # the subscriber both swallow their own errors.
  class Railtie < ::Rails::Railtie
    # Install the Base-level after_discard hook EARLY — initializers run before
    # eager loading, and on_load(:active_job) fires the moment ActiveJob::Base
    # loads, so the hook lands in ActiveJob::Base.after_discard_procs BEFORE
    # any of the host's job classes are defined. That ordering is correctness,
    # not taste: after_discard_procs is a copy-on-write class_attribute, so a
    # job class that registers its own after_discard at load time (canonical:
    # ApplicationJob wiring an error tracker) snapshots Base's array — a hook
    # registered later (e.g. in after_initialize) would silently never fire
    # for that class or its descendants. The hook itself only delegates to
    # Stablemate.execution_subscriber, which stays nil — hook a no-op — until
    # the boot wiring below arms it behind the api_key/enabled_in? gates.
    initializer "stablemate.install_discard_hook" do
      ActiveSupport.on_load(:active_job) { Stablemate::Execution::Subscriber.install_discard_hook }
    end

    rake_tasks do
      task_file = File.expand_path("tasks/stablemate.rake", __dir__)
      # Defensive: a packaging slip (the .rake not shipped) must never crash the
      # host app's `rake`. Load only when present; warn otherwise.
      if File.exist?(task_file)
        load task_file
      else
        Stablemate.logger.warn("[stablemate] rake tasks not found at #{task_file}; stablemate:sync unavailable.")
      end
    end

    # After the app initializes, sync (caching ping URLs) and attach Layer 1.
    # Gated on api_key presence AND the environment allow-list — see the
    # rationale on Configuration#environments (production-only by default).
    config.after_initialize do
      next unless Stablemate.config.api_key
      next unless Stablemate.config.enabled_in?

      registrar = Registrars::SolidQueueRecurring.new
      registration = Registration.new(registrar:)

      # Layer 2 on boot. With register_on_boot on (default) we upsert monitors
      # from recurring.yml; with it off we only load existing monitors' ping URLs
      # read-only, so the gem never creates or edits monitors from recurring.yml
      # but Layer 1 still has URLs to ping. The same callable backs the
      # stale-ping resync below, so a rotated token refreshes URLs via whichever
      # path the host opted into (never upserting when registration is off).
      load_ping_urls = -> {
        Stablemate.config.register_on_boot ? registration.sync! : registration.refresh_ping_urls!
      }
      load_ping_urls.call

      # Pass the bounded refresh so a ping rejected after a token rotation reloads
      # the cached URLs (the subscriber throttles it to once per interval).
      # subscribe_discards! ARMS terminal-failure reporting — unhandled raise,
      # retry_on exhausted, discard_on, as error notices on the same ping URL —
      # by assigning Stablemate.execution_subscriber, the delegation target of
      # the Base-level hook installed by the initializer above (Rails ≥ 7.1;
      # guarded inside, so older hosts silently keep missed-beat-only
      # detection).
      Execution::Subscriber.new(
        class_to_keys: registrar.class_to_keys,
        resync: load_ping_urls
      ).subscribe!.subscribe_discards!
    rescue StandardError => e
      Stablemate.logger.warn("[stablemate] boot wiring skipped: #{e.class}: #{e.message}")
    end
  end
end
