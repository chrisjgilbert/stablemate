# frozen_string_literal: true

namespace :stablemate do
  desc "Register/refresh monitors from config/recurring.yml (idempotent)"
  task sync: :environment do
    cache = Stablemate.sync!
    # Name the environment: recurring.yml is scoped to its section, so "synced
    # 0" in the wrong environment should point at the cause, not mystify.
    if cache
      puts "[stablemate] synced #{cache.size} monitor(s) for environment '#{Stablemate.config.environment}'."
    else
      warn "[stablemate] sync failed — see the log for details."
    end
  end
end
