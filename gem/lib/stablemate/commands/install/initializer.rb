# frozen_string_literal: true

require "fileutils"

module Stablemate
  module Commands
    class Install
      # `config/initializers/stablemate.rb`, written once (§6.6).
      #
      # The one rule this file exists to keep: **no key is ever written into it.**
      # The skeleton reads the environment first and falls back to Rails
      # encrypted credentials, which is the server's own documented pattern —
      # writing the key here would commit a credential to git, and it is a
      # committed file by definition.
      class Initializer
        PATH = "config/initializers/stablemate.rb"

        def initialize(root:, endpoint:)
          @root = root
          @endpoint = endpoint
        end

        def path = PATH

        def exist? = File.exist?(absolute_path)

        # Idempotent for code: a re-run leaves an existing initializer exactly as
        # the user left it — they may have added c.monitors, c.overrides or an
        # environment list, and install has no way to merge that. (Secrets are
        # the opposite; see EnvFile.)
        def write!
          FileUtils.mkdir_p(File.dirname(absolute_path))
          File.write(absolute_path, skeleton)
        end

        private
          attr_reader :root, :endpoint

          def absolute_path = File.expand_path(PATH, root)

          # `.presence`, not truthiness: a set-but-empty STABLEMATE_PING_KEY is
          # "", which is truthy — the gate would pass and every check-in would
          # carry `Authorization: Bearer ` for a permanent 401.
          #
          # The endpoint is baked in as the fallback rather than left to the
          # default, so a self-hosted install keeps pointing at the host it was
          # just verified against.
          def skeleton
            <<~RUBY
              # frozen_string_literal: true

              # Written by `bin/rails stablemate:install`.
              #
              # Monitors are registered by `bin/rails stablemate:sync`, from your deploy
              # hook — booting the app registers nothing and makes no network call.
              Stablemate.configure do |c|
                # Nothing secret is committed with this file: the environment first, then
                # Rails encrypted credentials (`bin/rails credentials:edit`).
                c.api_key = ENV["STABLEMATE_API_KEY"].presence ||
                            Rails.application.credentials.dig(:stablemate, :api_key)
                c.ping_key = ENV["STABLEMATE_PING_KEY"].presence ||
                             Rails.application.credentials.dig(:stablemate, :ping_key)
                c.endpoint = ENV["STABLEMATE_ENDPOINT"].presence || #{endpoint.to_s.inspect}

                # Work that is not a Rails job — a shell cron, a backup script — declared
                # here so it registers through the same command. Seconds, and the work
                # checks itself in: `stablemate:install` prints the curl line for each.
                # c.monitors = { "pg_backup" => { interval: 86_400, grace: 7_200 } }

                # A derived interval is the LARGEST gap between runs, so a weekday-only
                # `0 9 * * 1-5` derives 72h from the Friday→Monday hole. Tighten it here:
                # c.overrides = { "weekday_report" => { interval: 93_600 } }
              end
            RUBY
          end
      end
    end
  end
end
