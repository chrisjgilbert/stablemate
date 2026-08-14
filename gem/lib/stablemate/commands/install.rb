# frozen_string_literal: true

require_relative "../registration"
require_relative "install/env_file"
require_relative "install/initializer"
require_relative "install/kamal_hook"
require_relative "install/preview"
require_relative "install/verification"

module Stablemate
  module Commands
    # `bin/rails stablemate:install` — the first two minutes of the product
    # (§6.6). Paste one line, watch something real happen in the terminal, be
    # ready to deploy, without faking the one thing this product exists to be
    # truthful about.
    #
    # **It is dry-run by design and registers nothing.** Everything it shows is
    # real — config written, derivations computed, credentials proven end-to-end
    # against the live server — and none of it is a monitor. Onboarding is
    # exactly the pressure that would erode §6.1's environment guard ("just
    # FORCE=1 the first time"); registering nothing removes the temptation.
    #
    # What it does, in the order the user reads it:
    #
    # 1. writes `config/initializers/stablemate.rb`, once, with no key in it;
    # 2. previews what PRODUCTION will register, naming the section it read;
    # 3. verifies BOTH credentials with two real calls, naming the one that fails;
    # 4. persists the keys where they belong — an existing `.env`, or the printed
    #    `credentials:edit` lines;
    # 5. writes `.kamal/hooks/post-deploy`, because the flow dies without it;
    # 6. prints the ready-to-paste `curl` block for `c.monitors` entries — here,
    #    and only here: sync's stdout is deploy logs (§6.1).
    class Install
      API_KEY = "STABLEMATE_API_KEY"
      PING_KEY = "STABLEMATE_PING_KEY"
      # The preview's section, overridable for unusual layouts. Explicit, and NOT
      # RAILS_ENV: that one also decides what Rails itself just booted as, so
      # borrowing it would make previewing the staging section a different app.
      ENVIRONMENT = "STABLEMATE_ENVIRONMENT"

      # What the preview pins itself to. §6.6's trap in one constant: the
      # registrar resolves recurring.yml's section from the CURRENT environment,
      # install runs on a dev machine, and an unpinned preview therefore shows
      # the development resolution — zero tasks, measured, for the standard
      # production-sectioned layout.
      DEFAULT_ENVIRONMENT = "production"

      MISSING_KEYS = "install needs both keys, and they are shown once — regenerate the pair from your " \
                     "project's setup panel and paste the whole line it renders:\n" \
                     "  bin/rails stablemate:install #{API_KEY}=sm_live_… #{PING_KEY}=sm_ping_…\n" \
                     "Nothing was written."

      def initialize(config: Stablemate.config, root: nil, env: ENV, client: nil,
                     registration: nil, out: $stdout, err: $stderr)
        @config = config
        @root = root || default_root
        @env = env
        @client = client
        @registration = registration
        @out = out
        @err = err
      end

      # @return [Boolean] false when the run must exit non-zero. The rake task
      #   turns that into the exit status and nothing else.
      def install!
        return failed(MISSING_KEYS) unless keys?

        write_initializer
        preview!

        # Keys are persisted BEFORE the verification gate, and the ordering is
        # the whole point. Both keys are shown exactly once — the setup panel
        # renders them and nothing can ever re-display them — so a run that
        # exits without writing them costs the user the pair. The most likely
        # verification failure is the endpoint being briefly unreachable or
        # c.endpoint being wrong, which says nothing about the keys themselves;
        # discarding them there is the one outcome that is expensive to undo,
        # and the failure message already promised nothing depending on the
        # server had been written.
        persist_keys
        return failed(*verification.failure_messages) unless verify!

        install_deploy_hook
        print_check_in_lines
        print_next_steps
        true
      rescue ConfigurationError => e
        # Raised by the registrars and by c.overrides. Install is the first place
        # a typo in that file can be caught at all, and reporting it here — with
        # nothing registered either way — costs a deploy less than finding it in
        # a post-deploy hook.
        failed(e.message)
      end

      private
        attr_reader :config, :root, :env, :out, :err

        # --- 1. The initializer, written once (§6.6) ------------------------

        # Idempotent for CODE, rotating for SECRETS. With the file already there
        # install refuses to clobber it — the user may have added c.monitors or
        # c.overrides — but the run carries on and updates the keys, because that
        # is the lost-key recovery loop: regenerate, paste, done.
        def write_initializer
          if initializer.exist?
            say("already configured — updating keys (#{initializer.path} left as you have it)")
          else
            initializer.write!
            say("writing #{initializer.path}")
          end
        end

        def initializer
          @initializer ||= Initializer.new(root:, endpoint: config.endpoint)
        end

        # --- 2. What PRODUCTION will register (§6.6) ------------------------

        def preview!
          Preview.new(result: registration.preview, environment: preview_environment,
                      path: config.recurring_path, file_present: File.exist?(recurring_path),
                      tasks_in_section: tasks_in_section?)
                 .lines.each { |line| out.puts(line) }
        end

        # A file with tasks nobody can register (every one `command:`-only) is
        # still a file with tasks: the preview lists the skips, so calling the
        # section empty would contradict the lines under it.
        def tasks_in_section?
          !(registrar.tuples.empty? && registrar.skips.empty?)
        end

        # The client is threaded through deliberately. Install registers nothing,
        # and the test that pins that asserts on a double which raises from
        # sync_monitors — but a double only proves something if a regression
        # would REACH it. Letting Registration build its own Client put the real
        # transport on the path a regression takes and the double on a path
        # nothing travels, so "registers nothing" was asserted against a stub
        # that could not have been called either way.
        def registration
          @registration ||= Registration.new(registrar:, config: preview_config, client:)
        end

        # Pinned to the previewed environment, explicitly. This is a read-only
        # parse of the file — no guard applies, nothing is sent — so pinning it
        # costs nothing and answers the only question worth asking.
        def registrar
          @registrar ||= Registrars::SolidQueueRecurring.new(
            recurring_path:, environment: preview_environment, config: preview_config
          )
        end

        # The same pin, for everything downstream of the parse that has its own
        # opinion about which environment this is. c.overrides names the
        # environment when it rejects a key, and "matches no task … in
        # environment 'development'" printed beside a list of PRODUCTION's task
        # keys sends the operator to the wrong section of the file.
        #
        # Dup'd rather than assigned to: `Stablemate.config` is the live object
        # the host app is about to boot with, and install is previewing an
        # environment it is deliberately not running in.
        def preview_config
          @preview_config ||= config.dup.tap { |copy| copy.environment = preview_environment }
        end

        def preview_environment
          @preview_environment ||= presence(env[ENVIRONMENT]) || DEFAULT_ENVIRONMENT
        end

        # Resolved against the app root rather than the process's directory: the
        # printed path stays the relative one the user recognises, but the parse
        # cannot depend on where they happened to be standing.
        def recurring_path
          @recurring_path ||= File.expand_path(config.recurring_path, root)
        end

        # --- 3. Two real calls (§6.6) ---------------------------------------

        def verify!
          verification.verify!
          say(verification.line)
          verification.ok?
        end

        def verification
          @verification ||= Verification.new(client: client, api_key:, ping_key:, endpoint: config.endpoint)
        end

        def client
          @client ||= Client.new(config)
        end

        # --- 4. Secrets, never in a committed file (§6.6) --------------------

        def persist_keys
          if env_file.exist?
            env_file.write!
            say("writing #{env_file.path} (#{API_KEY}, #{PING_KEY}) — your dev machine only")
          else
            print_credentials_instructions
          end
        end

        def env_file
          @env_file ||= EnvFile.new(root:, values: { API_KEY => api_key, PING_KEY => ping_key })
        end

        # No `.env` to append to, so say where the keys go instead. The skeleton
        # falls back to credentials, so this is the same pair of names arriving
        # by the other supported route.
        def print_credentials_instructions
          say("no #{env_file.path} here — put the keys in your credentials instead " \
              "(`bin/rails credentials:edit`):")
          say("  stablemate:")
          say("    api_key: #{api_key}")
          say("    ping_key: #{ping_key}")
        end

        # --- 5. The deploy hook, or the line for your own CI (§6.6) ---------

        # Nothing declared yet means the hook would be a landmine, not a
        # convenience: §6.1 requires `stablemate:sync` to exit NON-ZERO when it
        # registers nothing — that exit status is the only evidence a deploy has
        # that anything is monitored — so a hook written for an app with no
        # recurring jobs and no c.monitors fails the very next deploy, and every
        # one after it, until the user deletes a file they never asked for. The
        # two rules are both right and they collide only here. Say what to do
        # instead; install is re-runnable, which is what makes that a real
        # instruction rather than a brush-off.
        def install_deploy_hook
          return say_nothing_to_register unless anything_declared?
          return say_no_kamal unless hook.kamal?

          if hook.exist?
            say("#{hook.path} already exists — left alone. Make sure it runs: #{hook.command}")
          else
            hook.write!
            say("writing #{hook.path} (kamal detected) — registration runs there, on every deploy")
          end
        end

        # Registerable tasks OR c.monitors declarations — the same union sync
        # sends, so this predicate and sync's register-nothing exit agree by
        # construction rather than by coincidence.
        def anything_declared?
          registrar.tuples.any? || config.monitors.any?
        end

        def say_nothing_to_register
          say("no deploy hook written yet: there is nothing to register, and the sync command " \
              "deliberately fails a deploy that registers nothing. Declare a recurring job (or a " \
              "c.monitors entry), then re-run this command to wire the hook up.")
        end

        def say_no_kamal
          say("no #{KamalHook::DIRECTORY}/ here, so nothing was written for deploys. Run this from your " \
              "own deploy pipeline, IN the production environment, after each deploy:")
          say("  bin/rails stablemate:sync")
        end

        def hook
          @hook ||= KamalHook.new(root:)
        end

        # --- 6. The `curl` block, here and only here (§6.1, §6.6) -----------

        # `c.monitors` entries have no job class by definition, so nothing in the
        # host can check them in — the work itself must. This block embeds the
        # live ping key, which is why it belongs to install and not to sync:
        # install is an interactive dev-machine run whose own invocation already
        # carries the keys, while sync's stdout is a deploy log that lives
        # forever.
        def print_check_in_lines
          declared = config.monitors.to_h.keys
          return if declared.empty?

          declared.each do |key|
            say("")
            say("check in #{key} from the work itself (this embeds your live ping key):")
            say("  curl -X POST -H \"Authorization: Bearer #{ping_key}\" \\")
            say("    #{client.check_in_uri(key.to_s)}")
          end
        end

        # --- The closing instructions (§6.6) --------------------------------

        # The step most likely to be left implicit and the one that gates the
        # whole flow: the sync runs INSIDE the production container (§6.2), and
        # the `.env` this command just wrote serves the dev machine only.
        def print_next_steps
          say("")
          say("next: add both keys to your production secrets (.kamal/secrets, or the deployed app's " \
              "credentials)")
          say("      — the sync runs in the container, and your local .env doesn't ship.")
          say("then deploy, and watch: #{dashboard_url}")
        end

        def dashboard_url
          URI.join(config.endpoint, "/projects")
        rescue StandardError
          config.endpoint
        end

        # --- The keys themselves --------------------------------------------

        def keys? = !api_key.nil? && !ping_key.nil?

        def api_key = presence(env[API_KEY])

        def ping_key = presence(env[PING_KEY])

        # A set-but-empty variable is truthy in Ruby, and a whitespace-only paste
        # is the shape a wrapped terminal produces. Left as "", every request
        # would carry `Authorization: Bearer ` for a permanent 401.
        def presence(value)
          value = value.to_s.strip
          value unless value.empty?
        end

        def default_root
          defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : Dir.pwd
        end

        def say(line) = out.puts(line)

        # One prefixed line per message: both keys can fail at once, and a
        # joined-up blob would carry the `[stablemate]` marker on the first
        # sentence only — invisible to the grep that finds it in a deploy log.
        def failed(*messages)
          messages.each { |message| err.puts("[stablemate] #{message}") }
          false
        end
    end
  end
end
