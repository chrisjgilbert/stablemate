# frozen_string_literal: true

require_relative "lib/stablemate/version"

Gem::Specification.new do |spec|
  spec.name        = "stablemate"
  spec.version     = Stablemate::VERSION
  spec.authors     = [ "Stablemate" ]
  spec.summary     = "Auto-register and heartbeat your Solid Queue recurring jobs with Stablemate."
  spec.description = "Zero-per-job-code monitoring for Rails/Solid Queue: registers " \
                     "recurring tasks as monitors and pings on successful runs."
  spec.homepage    = "https://stablemate.dev"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"

  # Package everything under lib/ (not just *.rb) so the rake task
  # (lib/stablemate/tasks/stablemate.rake), which the railtie loads, ships with
  # the installed gem. Globbing only *.rb left it out and broke `rake` in a real
  # install.
  spec.files = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = [ "lib" ]

  # Fugit parses the recurring.yml cron schedules into intervals.
  spec.add_dependency "fugit", ">= 1.8"

  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake", ">= 13.0"
  # Used only in tests to exercise the real perform.active_job notification path
  # (Layer 1 is backend-agnostic — it keys off ActiveSupport::Notifications).
  spec.add_development_dependency "activesupport", ">= 7.0"
end
