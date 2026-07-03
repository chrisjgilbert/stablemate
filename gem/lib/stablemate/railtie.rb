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
      Registration.new(registrar:).sync!

      Execution::Subscriber.new(class_to_keys: registrar.class_to_keys).subscribe!
    rescue StandardError => e
      Stablemate.logger.warn("[stablemate] boot wiring skipped: #{e.class}: #{e.message}")
    end
  end
end
