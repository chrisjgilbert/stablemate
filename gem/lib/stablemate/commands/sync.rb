# frozen_string_literal: true

require_relative "../registration"
require_relative "sync/report"

module Stablemate
  module Commands
    # `bin/rails stablemate:sync` — the management surface for monitor config
    # (§6.1), and after §3.1 the only writer of it. Everything the rake task used
    # to do inline lives here instead, so it can be driven without booting Rails
    # or shelling out to rake.
    #
    # Four contracts, each of which the old six-line task broke:
    #
    # - **It refuses to run outside its configured environment**, with `FORCE=1`.
    #   `enabled_in?` existed only in the railtie and this command never
    #   consulted it, so a local run registered the DEVELOPMENT section into the
    #   production project and exited 0 — a nuisance while boot sync corrected
    #   it, and now the entire monitor set.
    # - **It exits non-zero when it registers nothing**, on all four paths.
    #   Under CLI-only registration "the command exited 0" is the whole of a
    #   deploy's evidence that anything is monitored, and a free plan capped at
    #   five refusing the sixth job used to print `synced 0` and exit 0.
    # - **It reports what was refused and what is orphaned**, because those jobs
    #   are not monitored and this run is the last thing that will mention them.
    # - **It never prints a credential.** Its stdout is deploy logs: sync runs
    #   from the post-deploy hook (§6.2), so a ready-to-paste `curl` line here —
    #   which embeds the live ping key — writes a credential into every CI run's
    #   log, forever. That block lives in `stablemate:install` (§6.6), an
    #   interactive dev-machine run whose own invocation already carries the keys.
    class Sync
      # Rake idiom, and only the spellings people actually type: `FORCE=0` must
      # not mean "force", which is what the bare `ENV.key?` check reads as.
      TRUTHY = %w[1 true yes on].freeze

      TRANSPORT_FAILURE = "sync failed and NOTHING was registered — the request did not complete, or the " \
                          "server refused it outright (a 401 means the API key is wrong or revoked). The " \
                          "reason is on the gem's log. Every monitor keeps whatever the last successful " \
                          "sync left it with; re-run this command."

      def initialize(config: Stablemate.config, registration: nil, env: ENV, out: $stdout, err: $stderr)
        @config = config
        @registration = registration
        @env = env
        @out = out
        @err = err
      end

      # @return [Boolean] false when the run must fail the deploy. The caller
      #   (the rake task) turns that into the exit status and nothing else.
      def sync!
        # §3.1's pinned order starts here: the environment guard FIRST, before
        # the parse, the override validation and the request. Everything below
        # reads recurring.yml's section for the CURRENT environment, so a run
        # that got past this line would overwrite the project's monitor set with
        # some other environment's tasks.
        return refuse_environment unless permitted?

        result = registration.sync!(prune: prune?)
        return failed(TRANSPORT_FAILURE) if result.nil?

        report(result)
        # Before the register-nothing exit, deliberately: a run the server
        # refused wholesale still holds an envelope, and its operator is exactly
        # the one who needs to hear that their two credentials name different
        # projects.
        warn_ping_key_mismatch(result)
        return failed(nothing_registered(result)) unless result.registered?

        true
      rescue ConfigurationError => e
        # Raised by the registrars and by c.overrides, and deliberately ahead of
        # the register-nothing exits (§3.1): an override typo reported only on a
        # run that would otherwise have registered something is a typo reported
        # never, and the job keeps exactly the window the override existed to
        # correct.
        failed(e.message)
      end

      private
        attr_reader :config, :env, :out, :err

        def registration
          @registration ||= Registration.new(config:)
        end

        def report(result)
          Report.new(result, environment: config.environment, recurring_path: config.recurring_path)
                .lines.each { |line| out.puts(line) }
        end

        def permitted?
          config.enabled_in? || flag?("FORCE")
        end

        def prune?
          flag?("PRUNE")
        end

        def flag?(name)
          TRUTHY.include?(env[name].to_s.strip.downcase)
        end

        def refuse_environment
          failed("refusing to sync from '#{config.environment}': c.environments is " \
                 "#{Array(config.environments).inspect}. #{config.recurring_path} is section-scoped, so this " \
                 "run would replace the project's monitor settings with the tasks in the " \
                 "'#{config.environment}' section. Run it in the environment you mean to register — from a " \
                 "post-deploy hook, `kamal app exec --reuse \"bin/rails stablemate:sync\"` — or re-run with " \
                 "FORCE=1 if you really mean this one.")
        end

        # The two shapes of registering nothing are one exit status and two
        # different remedies, so they get two different sentences.
        def nothing_registered(result)
          if result.entries.empty?
            "registered nothing, so NOTHING IS MONITORED: no task in #{config.recurring_path} (section " \
            "'#{config.environment}') and no c.monitors entry could be registered. Any skip above says why; " \
            "an empty list means the file has no tasks for this environment."
          else
            "registered nothing, so NOTHING IS MONITORED: the server registered none of the " \
            "#{result.entries.size} entries this run sent — each refusal is printed above."
          end
        end

        # §9.4 — the two credentials can disagree, and nothing else in the system
        # can notice. Registration follows the API key; check-ins follow the ping
        # key; point them at different projects and this run's monitors go down
        # permanently while the jobs behind them run fine, with every symptom
        # reading "your job is down". Impossible with one credential, permanent
        # with two, and only visible HERE: boot makes no network call (§6.5), so
        # the command is the only process that ever holds a registration response
        # to compare against.
        #
        # A warning, not a failure: the registration itself was fine, and failing
        # the deploy would punish a correct half of the config. No escalation
        # either — an API key can already list every monitor in its project.
        def warn_ping_key_mismatch(result)
          live = result.ping_key_last4
          configured = last4(config.ping_key)
          # Nothing configured is a different fault with its own message ("no
          # ping_key configured — check-ins are DISABLED", §6.5): calling it a
          # MISMATCH would send the operator hunting for the wrong project.
          return if live.nil? || configured.nil? || live.include?(configured)

          warned("WARNING: the ping key configured here (…#{configured}) is #{known(live)}. " \
                 "Registration followed the API KEY into this project; check-ins carry the PING KEY, so " \
                 "they are landing in a DIFFERENT project — or nowhere. Every monitor this run registered " \
                 "will go down while the jobs behind them run fine. Copy BOTH keys from the same project's " \
                 "setup panel (during a rotation, either of the two live keys is fine).")
        end

        def known(live)
          return "not one of this project's live ping keys (#{live.map { |key| "…#{key}" }.join(', ')})" if
            live.any?

          "not one of this project's ping keys — it has none at all, so every check-in is being rejected"
        end

        # The masked form the dashboard already shows (`sm_ping_••••1234`), which
        # is why naming it here leaks nothing — and why the prefix stays off it:
        # this stream is a deploy log, and a line carrying `sm_ping_` is one
        # careless edit away from carrying the rest of the key with it.
        def last4(key)
          key = key.to_s
          key[-4..] unless key.empty?
        end

        # A fatal line is a warning that also decides the exit status, so the two
        # share one channel and one prefix: a deploy log is grepped for
        # `[stablemate]`, and a diagnostic that missed the prefix would be
        # invisible in exactly the pile of output it exists to stand out from.
        def failed(message)
          warned(message)
          false
        end

        def warned(message)
          err.puts("[stablemate] #{message}")
        end
    end
  end
end
