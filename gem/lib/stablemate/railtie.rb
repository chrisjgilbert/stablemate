# frozen_string_literal: true

require "rails/railtie"
require_relative "boot"

module Stablemate
  # Wires the gem into a host Rails app with zero per-job code. Boot must never be
  # blocked or crashed by Stablemate: Boot#wire! and the subscriber both swallow
  # their own errors.
  class Railtie < ::Rails::Railtie
    # Install the Base-level after_discard hook EARLY, so it lands in
    # ActiveJob::Base.after_discard_procs BEFORE any of the host's job classes are
    # defined. That ordering is correctness, not taste: after_discard_procs is a
    # copy-on-write class_attribute, so a job class that registers its own
    # after_discard at load time snapshots Base's array — a hook registered later
    # would silently never fire for that class or its descendants.
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

    # Boot attaches the check-in listener and does nothing else (§6.5): no
    # registration, no fetch, no network. Every gate, every log line and the
    # rescue that keeps a broken recurring.yml from taking the host's boot down
    # live in Stablemate::Boot, which is testable without booting a Rails app.
    config.after_initialize { Stablemate::Boot.new.wire! }
  end
end
