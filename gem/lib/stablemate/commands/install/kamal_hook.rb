# frozen_string_literal: true

require "fileutils"

module Stablemate
  module Commands
    class Install
      # `.kamal/hooks/post-deploy`, because the whole flow dies without it (§6.6).
      #
      # The dashboard's "waiting for your first sync" waits forever if nothing
      # runs the sync on deploy, and an install that ends "deploy, then watch"
      # while silently depending on a hook the user has to discover in another
      # section is a guaranteed 11pm debugging session. This is repo config, not
      # a secret, so install can simply write it.
      class KamalHook
        DIRECTORY = ".kamal"
        PATH = ".kamal/hooks/post-deploy"

        # `kamal app exec --reuse`, not a bare `bin/rails stablemate:sync`: hooks
        # execute on the DEPLOYING machine, not in the container, so the bare
        # form runs on the laptop or CI runner with RAILS_ENV unset — i.e.
        # development, i.e. the environment guard refusing the run (§6.2).
        COMMAND = 'kamal app exec --reuse "bin/rails stablemate:sync"'

        def initialize(root:)
          @root = root
        end

        def path = PATH

        def command = COMMAND

        def kamal? = Dir.exist?(File.expand_path(DIRECTORY, root))

        def exist? = File.exist?(absolute_path)

        # 0755 because Kamal runs a hook only if it is executable — a hook
        # written 0644 is silently never run, which is the same outcome as not
        # writing one at all and much harder to notice.
        def write!
          FileUtils.mkdir_p(File.dirname(absolute_path))
          File.write(absolute_path, script)
          FileUtils.chmod(0o755, absolute_path)
        end

        private
          attr_reader :root

          def absolute_path = File.expand_path(PATH, root)

          # post-deploy, and pre-deploy is wrong in a way that looks right: it
          # runs before `app:boot`, so `--reuse` execs in the OLD container
          # against the old image's recurring.yml and the job you just added is
          # never registered.
          def script
            <<~SH
              #!/bin/sh
              # Written by `bin/rails stablemate:install`.
              #
              # Registers this deploy's recurring jobs as monitors. It runs IN the
              # container (`app exec --reuse`) because hooks themselves run on the
              # deploying machine, where RAILS_ENV is unset — and the command refuses to
              # register one environment's tasks into another.
              #
              # Full convergence is a policy you declare, not a mood: add PRUNE=1 to retire
              # monitors no task declares any more (reversibly — retiring keeps history).
              # As a rake-style argument, so no shell has to interpret it:
              #   #{COMMAND.sub('stablemate:sync', 'stablemate:sync PRUNE=1')}
              set -e
              #{COMMAND}
            SH
          end
      end
    end
  end
end
