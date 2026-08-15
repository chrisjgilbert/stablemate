# frozen_string_literal: true

namespace :stablemate do
  desc "Register/refresh monitors from config/recurring.yml (idempotent). " \
       "PRUNE=1 retires monitors no task declares any more; FORCE=1 overrides the environment guard."
  task sync: :environment do
    # The guard, the report, the reasons and the exit status all live in
    # Stablemate::Commands::Sync — an object, so the behaviour is testable
    # without booting Rails or shelling out to rake, and so this file has exactly
    # one decision left to make.
    #
    # That decision: a false answer must FAIL THE DEPLOY. Under CLI-only
    # registration "the command exited 0" is the entire evidence a deploy has
    # that anything is monitored (§6.1), and every way of registering nothing
    # used to exit 0 — two of them without making a request at all.
    #
    # `exit`, not `abort`: the command has already said what went wrong, on the
    # right stream, in the shape §6.1 pins.
    exit 1 unless Stablemate::Commands::Sync.new.sync!
  end

  desc "Set up Stablemate: write the initializer, preview what production will register, and verify both " \
       "keys. Registers NOTHING. Usage: bin/rails stablemate:install " \
       "STABLEMATE_API_KEY=sm_live_… STABLEMATE_PING_KEY=sm_ping_… " \
       "(STABLEMATE_ENVIRONMENT=… previews another section)."
  task install: :environment do
    # Same one decision as sync, for the same reason: an install whose
    # credentials did not verify has proved nothing, and a green exit there is
    # the difference between finding out now and finding out when a job silently
    # stops being monitored (§6.6).
    #
    # The keys arrive as env-style rake arguments, which is why nothing is
    # declared here: `NAME=VALUE` on the command line is already in ENV by the
    # time this runs, under the same names the initializer skeleton reads.
    exit 1 unless Stablemate::Commands::Install.new.install!
  end
end
