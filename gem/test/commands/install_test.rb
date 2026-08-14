# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

# §6.6 — `bin/rails stablemate:install` is the first two minutes of the product,
# and it is DRY-RUN BY DESIGN: it writes config, previews what PRODUCTION will
# register, and proves both credentials end-to-end. It registers nothing, because
# onboarding is exactly the pressure that would erode §6.1's environment guard.
class InstallCommandTest < StablemateTest
  API_KEY = "sm_live_0123456789abcdefwxyz"
  PING_KEY = "sm_ping_fedcba9876543210wxyz"

  # The two verification calls (§6.6): the ping key against §5.5's endpoint, the
  # API key against GET /api/v1/monitors. Answers are per-key, so a test can
  # reject exactly one of them and assert the CLI names the right one.
  #
  # A real Client with its two network methods replaced, rather than a bare
  # double: the curl block install prints is addressed by the client itself, and
  # a hand-built URL in here would assert that the TEST can address a check-in.
  #
  # #sync_monitors raises rather than recording: "install registers nothing" is
  # the rule most likely to be lost to a helpful refactor, so the double makes
  # breaking it a test error rather than an assertion nobody wrote.
  class FakeVerifier < Stablemate::Client
    attr_reader :verified

    def initialize(answers, config)
      super(config)
      @answers = answers
      @verified = []
    end

    def verify_api_key(key)
      @verified << { key:, kind: :api }
      @answers.fetch(:api, :ok)
    end

    def verify_ping_key(key)
      @verified << { key:, kind: :ping }
      @answers.fetch(:ping, :ok)
    end

    def sync_monitors(**)
      raise "install must never register anything (§6.6)"
    end
  end

  Run = Struct.new(:ok, :out, :err, :root, :client, keyword_init: true)

  def configuration(environment: "development")
    config = Stablemate::Configuration.new
    config.environment = environment
    config.endpoint = "https://stablemate.example"
    config.logger = Logger.new(StringIO.new)
    config
  end

  # A host app on disk: install writes into it, so every test gets a real
  # directory rather than a stubbed file system.
  def in_app
    Dir.mktmpdir("stablemate-install") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      yield root
    end
  end

  # The default recurring.yml is the shipped fixture: PRODUCTION-sectioned, which
  # is the whole trap §6.6 names — install runs on a dev machine, and an unpinned
  # preview would resolve the development section and show zero tasks.
  def write_recurring(root, body = File.read(fixture("recurring.yml")))
    File.write(File.join(root, "config", "recurring.yml"), body)
  end

  def keys = { "STABLEMATE_API_KEY" => API_KEY, "STABLEMATE_PING_KEY" => PING_KEY }

  def run_install(root:, config: configuration, env: keys, answers: {})
    client = FakeVerifier.new(answers, config)
    out = StringIO.new
    err = StringIO.new
    ok = Stablemate::Commands::Install.new(config:, root:, env:, client:, out:, err:).install!

    Run.new(ok:, out: out.string, err: err.string, root:, client:)
  end

  def initializer_path(root) = File.join(root, "config", "initializers", "stablemate.rb")

  def hook_path(root) = File.join(root, ".kamal", "hooks", "post-deploy")

  # --- Dry run by design (§6.6) -------------------------------------------

  # Everything install shows is real — config written, derivations computed,
  # credentials proven — and none of it registers a monitor. The FakeVerifier
  # raises on sync_monitors, so a run that tried would error here.
  def test_it_registers_nothing
    in_app do |root|
      write_recurring(root)

      run = run_install(root:)

      assert run.ok
      assert_equal %i[api ping].sort, run.client.verified.map { |call| call[:kind] }.sort
    end
  end

  # The trap the transcript hides: the registrar resolves recurring.yml's section
  # from the CURRENT environment and install runs on a dev machine, so an
  # unpinned preview shows the development resolution — zero tasks for the
  # standard production-sectioned layout. "What will be monitored" means what
  # PRODUCTION will register.
  def test_the_preview_reads_the_production_section_from_a_development_machine
    in_app do |root|
      write_recurring(root)

      run = run_install(root:, config: configuration(environment: "development"))

      assert_match(/daily_digest/, run.out)
      assert_match(/clear_sessions/, run.out)
      assert_match(/production/, run.out, "the preview must SAY which section it consulted")
    end
  end

  # One line per task, naming the number AND where it came from — the derivation
  # is half the line's job, and this is the moment the user can still fix it.
  def test_the_preview_names_the_derivation_per_task
    in_app do |root|
      write_recurring(root)

      run = run_install(root:)

      assert_match(/daily_digest.*every 24h.*derived from 'every day at 9am'/, run.out)
      assert_match(/db_backup.*skipped:.*command task/, run.out)
    end
  end

  # A c.monitors declaration is registered by the same command, so it belongs in
  # the same preview — and it is the one the curl block below is for.
  def test_declarations_are_previewed_beside_the_derived_tasks
    in_app do |root|
      write_recurring(root)
      config = configuration
      config.monitors = { "pg_backup" => { interval: 86_400 } }

      run = run_install(root:, config:)

      assert_match(/pg_backup.*every 24h.*declared in c\.monitors/, run.out)
    end
  end

  # A present file that resolves to zero tasks under that section is reported BY
  # NAME — a different message from the missing-file note, because the remedies
  # are different (write a production section vs. declare a recurring job).
  def test_a_present_file_with_no_tasks_in_the_section_is_reported_by_name
    in_app do |root|
      write_recurring(root, "development:\n  dev_smoke:\n    class: DevSmokeJob\n    schedule: every hour\n")

      run = run_install(root:)

      assert run.ok, "an empty section is not a failure — install still verifies"
      assert_match(/no tasks under 'production'/, run.out)
      assert_match(%r{config/recurring\.yml}, run.out)
      refute_match(/none found yet/, run.out)
    end
  end

  # A missing recurring.yml is a NOTE, not an error — the app may simply not have
  # recurring jobs yet. (Unlike sync, where registering nothing is a failure.)
  def test_a_missing_recurring_file_is_a_note_and_verification_still_runs
    in_app do |root|
      run = run_install(root:)

      assert run.ok
      assert_match(/none found yet/, run.out)
      assert_equal 2, run.client.verified.size
    end
  end

  # An unusual layout (a staging-only section, a host that registers from a
  # differently-named environment) needs a way through, and it must be explicit
  # rather than inherited from RAILS_ENV — which would also change what Rails
  # itself booted as.
  def test_the_previewed_section_can_be_overridden
    in_app do |root|
      write_recurring(root, "staging:\n  staging_only:\n    class: StagingJob\n    schedule: every hour\n")

      run = run_install(root:, env: keys.merge("STABLEMATE_ENVIRONMENT" => "staging"))

      assert_match(/staging_only/, run.out)
      assert_match(/staging/, run.out)
    end
  end

  # --- Verification: two real calls, and which key failed (§6.6) -----------

  def test_it_verifies_with_the_keys_from_the_command_line
    in_app do |root|
      config = configuration
      config.api_key = "sm_live_stale_from_the_environment"
      config.ping_key = "sm_ping_stale_from_the_environment"

      run = run_install(root:, config:)

      assert_equal [ API_KEY, PING_KEY ].sort, run.client.verified.map { |call| call[:key] }.sort
    end
  end

  # Server responses stay opaque; the CLI knows which request it made and names
  # the key. Naming neither would leave the user re-pasting both.
  def test_a_rejected_ping_key_is_named_and_exits_non_zero
    in_app do |root|
      write_recurring(root)

      run = run_install(root:, answers: { ping: :rejected })

      refute run.ok
      assert_match(/ping key/i, run.err)
      refute_match(/API key.*(rejected|invalid)/i, run.err)
    end
  end

  def test_a_rejected_api_key_is_named_and_exits_non_zero
    in_app do |root|
      write_recurring(root)

      run = run_install(root:, answers: { api: :rejected })

      refute run.ok
      assert_match(/API key/i, run.err)
    end
  end

  # Both calls are made even when the first fails: a user who pasted one line
  # wrong has probably pasted both wrong, and a run that stops at the first
  # costs them a second round trip to find out.
  def test_both_keys_are_checked_even_when_the_first_fails
    in_app do |root|
      run = run_install(root:, answers: { api: :rejected, ping: :rejected })

      refute run.ok
      assert_equal 2, run.client.verified.size
      assert_match(/API key/i, run.err)
      assert_match(/ping key/i, run.err)
    end
  end

  # A server that never answered says nothing about the key. Reporting it as a
  # bad credential sends the user to regenerate a pair that was fine, when the
  # remedy is the endpoint or the network.
  def test_an_unreachable_server_is_not_reported_as_a_bad_key
    in_app do |root|
      run = run_install(root:, answers: { api: :unreachable, ping: :unreachable })

      refute run.ok
      assert_match(%r{https://stablemate\.example}, run.err)
      refute_match(/revoke|regenerate/i, run.err)
    end
  end

  # A failed verification must not persist the keys it just proved wrong.
  def test_a_failed_verification_writes_no_keys_and_no_hook
    in_app do |root|
      File.write(File.join(root, ".env"), "EXISTING=1\n")
      FileUtils.mkdir_p(File.join(root, ".kamal"))

      run = run_install(root:, answers: { ping: :rejected })

      refute run.ok
      assert_equal "EXISTING=1\n", File.read(File.join(root, ".env"))
      refute File.exist?(hook_path(root))
    end
  end

  # --- Secrets never land in committed files (§6.6) ------------------------

  def test_the_initializer_reads_env_then_credentials_and_carries_no_key
    in_app do |root|
      run = run_install(root:)

      skeleton = File.read(initializer_path(root))
      refute_includes skeleton, API_KEY, "writing keys into the initializer commits credentials to git"
      refute_includes skeleton, PING_KEY
      assert_includes skeleton, 'ENV["STABLEMATE_API_KEY"]'
      assert_includes skeleton, 'ENV["STABLEMATE_PING_KEY"]'
      assert_includes skeleton, "Rails.application.credentials.dig(:stablemate, :api_key)"
      assert_includes skeleton, "Rails.application.credentials.dig(:stablemate, :ping_key)"
      assert_match(%r{writing config/initializers/stablemate\.rb}, run.out)
    end
  end

  # ONE NAME EVERYWHERE: the argument, the initializer skeleton and the .env
  # append all spell it the same, or a green install boots the host into "no
  # ping_key configured" with no hint why.
  def test_keys_are_appended_to_an_existing_env_file_under_the_argument_names
    in_app do |root|
      File.write(File.join(root, ".env"), "DATABASE_URL=postgres://localhost/app\n")

      run = run_install(root:)

      env = File.read(File.join(root, ".env"))
      assert_includes env, "DATABASE_URL=postgres://localhost/app", "other entries survive"
      assert_includes env, "STABLEMATE_API_KEY=#{API_KEY}"
      assert_includes env, "STABLEMATE_PING_KEY=#{PING_KEY}"
      assert_match(/\.env/, run.out)
    end
  end

  # The lost-key recovery loop: regenerate from the panel, paste the new line,
  # done. Refusing the .env update the way the initializer is refused would
  # dead-end it with a green-looking run still carrying dead keys.
  def test_a_re_run_updates_the_env_values_in_place
    in_app do |root|
      File.write(File.join(root, ".env"), "STABLEMATE_API_KEY=sm_live_old\nOTHER=keep\n")

      run_install(root:)

      env = File.read(File.join(root, ".env"))
      refute_includes env, "sm_live_old"
      assert_equal 1, env.scan(/^STABLEMATE_API_KEY=/).size, "an update, not a second line"
      assert_includes env, "OTHER=keep"
      assert_includes env, "STABLEMATE_PING_KEY=#{PING_KEY}"
    end
  end

  # With no .env there is nothing to append to, and creating one would be a file
  # the host does not read — a silent no-op that looks like it worked. Print the
  # credentials lines instead: that path works everywhere, and the skeleton
  # already falls back to it.
  def test_with_no_env_file_it_prints_the_credentials_lines_instead
    in_app do |root|
      run = run_install(root:)

      refute File.exist?(File.join(root, ".env")), "install must not invent a .env the app never reads"
      assert_match(/credentials:edit/, run.out)
      assert_match(/#{Regexp.escape(API_KEY)}/, run.out)
      assert_match(/#{Regexp.escape(PING_KEY)}/, run.out)
    end
  end

  # A duplicated assignment is last-wins for dotenv, so rewriting only the first
  # one leaves the stale value in charge: install would report success and exit 0
  # while the app boots with a dead key — the silent-success shape this whole
  # command exists to remove.
  def test_every_assignment_of_a_key_is_updated_not_just_the_first
    in_app do |root|
      File.write(File.join(root, ".env"),
                 "STABLEMATE_PING_KEY=sm_ping_first\nOTHER=keep\nSTABLEMATE_PING_KEY=sm_ping_second\n")

      run_install(root:)

      env = File.read(File.join(root, ".env"))
      refute_includes env, "sm_ping_first"
      refute_includes env, "sm_ping_second"
      assert_equal 2, env.scan(/^STABLEMATE_PING_KEY=#{Regexp.escape(PING_KEY)}$/).size
    end
  end

  # --- Idempotent for code, rotating for secrets (§6.6) --------------------

  # The second run must carry DIFFERENT keys, or the closing assertion is already
  # satisfied by the first one and says nothing about rotation at all — a no-op
  # persist_keys would pass it. This is the lost-key recovery loop: regenerate
  # from the panel, paste the new line, done. Refusing the .env update alongside
  # the initializer would dead-end that loop with a green-looking run still
  # carrying dead keys.
  def test_a_re_run_refuses_to_clobber_the_initializer_but_still_rotates_the_keys
    rotated = { "STABLEMATE_API_KEY" => "sm_live_rotatedrotatedrotated00",
                "STABLEMATE_PING_KEY" => "sm_ping_rotatedrotatedrotated00" }

    in_app do |root|
      File.write(File.join(root, ".env"), "STABLEMATE_API_KEY=sm_live_old\n")
      run_install(root:)
      File.write(initializer_path(root), "# hand-edited by the user\n")

      run = run_install(root:, env: rotated)

      assert run.ok
      assert_equal "# hand-edited by the user\n", File.read(initializer_path(root))
      assert_match(/already configured/, run.out)

      env = File.read(File.join(root, ".env"))
      assert_includes env, "STABLEMATE_API_KEY=#{rotated["STABLEMATE_API_KEY"]}"
      assert_includes env, "STABLEMATE_PING_KEY=#{rotated["STABLEMATE_PING_KEY"]}"
      refute_includes env, API_KEY, "the superseded key must not survive the rotation"
      assert_equal 1, env.scan(/^STABLEMATE_API_KEY=/).size, "an update, not a second line"
    end
  end

  # --- The deploy hook, because the whole flow dies without it (§6.6) ------

  # The dashboard's "waiting for your first sync" waits forever if nothing runs
  # the sync on deploy, and an install that ends "deploy, then watch" while
  # silently depending on a hook the user must discover elsewhere is a
  # guaranteed 11pm debugging session.
  def test_it_writes_the_post_deploy_hook_when_kamal_is_present
    in_app do |root|
      FileUtils.mkdir_p(File.join(root, ".kamal"))

      run = run_install(root:)

      hook = File.read(hook_path(root))
      assert_includes hook, "stablemate:sync"
      # pre-deploy is wrong and looks right: it runs before app:boot, so --reuse
      # execs in the OLD container against the old image's recurring.yml.
      assert_includes hook, "kamal app exec --reuse"
      assert File.executable?(hook_path(root)), "kamal only runs a hook it can execute"
      assert_match(%r{\.kamal/hooks/post-deploy}, run.out)
    end
  end

  def test_it_refuses_to_clobber_an_existing_hook_and_says_what_to_add
    in_app do |root|
      FileUtils.mkdir_p(File.join(root, ".kamal", "hooks"))
      File.write(hook_path(root), "#!/bin/sh\necho mine\n")

      run = run_install(root:)

      assert run.ok
      assert_equal "#!/bin/sh\necho mine\n", File.read(hook_path(root))
      assert_match(/already exists/, run.out)
      assert_match(/kamal app exec --reuse/, run.out)
    end
  end

  def test_without_kamal_it_prints_the_line_for_the_users_own_ci
    in_app do |root|
      run = run_install(root:)

      refute File.exist?(hook_path(root))
      assert_match(/stablemate:sync/, run.out)
      assert_match(/production/, run.out)
    end
  end

  # --- The curl block, here and only here (§6.1, §6.6) --------------------

  # c.monitors entries have no job class by definition, so nothing can check them
  # in but the work itself. Install is an interactive dev-machine run whose own
  # invocation already carries the keys, so embedding the ping key adds no
  # exposure class — sync must never print it, because deploy stdout is logs.
  def test_the_curl_block_prints_for_declarations_with_the_live_ping_key
    in_app do |root|
      config = configuration
      config.monitors = { "pg_backup" => { interval: 86_400 } }

      run = run_install(root:, config:)

      assert_match(/curl -X POST/, run.out)
      assert_includes run.out, "Authorization: Bearer #{PING_KEY}"
      assert_includes run.out, "https://stablemate.example/api/v1/monitors/pg_backup/pings"
    end
  end

  def test_no_curl_block_without_declarations
    in_app do |root|
      write_recurring(root)

      run = run_install(root:)

      refute_match(/curl/, run.out, "a recurring.yml task checks itself in — there is nothing to paste")
    end
  end

  # A task key with a space would 404 forever if the printed line used
  # CGI.escape's "+" in a PATH segment.
  def test_the_curl_url_is_path_encoded
    in_app do |root|
      config = configuration
      config.monitors = { "pg backup" => { interval: 86_400 } }

      run = run_install(root:, config:)

      assert_includes run.out, "/api/v1/monitors/pg%20backup/pings"
    end
  end

  # --- Keys are required, and their absence is not a mystery --------------

  def test_it_refuses_to_run_without_keys_and_writes_nothing
    in_app do |root|
      run = run_install(root:, env: {})

      refute run.ok
      refute File.exist?(initializer_path(root))
      assert_match(/STABLEMATE_API_KEY/, run.err)
      assert_match(/STABLEMATE_PING_KEY/, run.err)
      assert_empty run.client.verified
    end
  end

  def test_a_missing_second_key_names_the_one_that_is_missing
    in_app do |root|
      run = run_install(root:, env: { "STABLEMATE_API_KEY" => API_KEY })

      refute run.ok
      assert_match(/STABLEMATE_PING_KEY/, run.err)
    end
  end

  # A set-but-empty variable is truthy in Ruby, and left as "" every request
  # would carry `Authorization: Bearer ` for a permanent 401.
  def test_a_blank_key_counts_as_missing
    in_app do |root|
      run = run_install(root:, env: keys.merge("STABLEMATE_PING_KEY" => "   "))

      refute run.ok
      assert_match(/STABLEMATE_PING_KEY/, run.err)
    end
  end

  # --- Config errors fail the run, as they do for sync (§3.1) -------------

  def test_a_config_error_is_reported_and_exits_non_zero
    in_app do |root|
      write_recurring(root)
      config = configuration
      config.monitors = { "pg_backup" => { grace: 60 } } # no interval:

      run = run_install(root:, config:)

      refute run.ok
      assert_match(/pg_backup/, run.err)
    end
  end

  # The whole run is pinned to the previewed section, not just the parse: an
  # override typo reported as "matches no task … in environment 'development'"
  # beside a list of PRODUCTION's task keys sends the operator to the wrong
  # section of the file to look for a key that was never going to be there.
  def test_an_override_typo_names_the_section_the_preview_read
    in_app do |root|
      write_recurring(root) # production-sectioned, run from a dev machine
      config = configuration(environment: "development")
      config.overrides = { "dailly_digest" => { interval: 93_600 } }

      run = run_install(root:, config:)

      refute run.ok
      assert_match(/dailly_digest/, run.err)
      assert_match(/production/, run.err)
      refute_match(/development/, run.err)
    end
  end

  # --- The closing instructions (§6.6) ------------------------------------

  # The local .env serves the dev machine only: the sync runs INSIDE the
  # production container, so leaving "get the keys to production" implicit is the
  # vaguest step gating the entire flow.
  def test_it_names_the_keys_to_production_step_and_where_to_watch
    in_app do |root|
      run = run_install(root:)

      assert_match(/production/, run.out)
      assert_match(/secrets|credentials/, run.out)
      assert_match(%r{https://stablemate\.example}, run.out)
    end
  end
end
