# frozen_string_literal: true

namespace :stablemate do
  desc "Register/refresh monitors from config/recurring.yml (idempotent)"
  task sync: :environment do
    cache = Stablemate.sync!
    if cache
      puts "[stablemate] synced #{cache.size} monitor(s)."
    else
      warn "[stablemate] sync failed — see the log for details."
    end
  end
end
