# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

# §6.1 — `bin/rails stablemate:sync` is the management surface for monitor config
# now that §3.1 makes it the only writer, so its output is product and its exit
# status is the entire evidence a deploy has that anything is monitored.
class SyncCommandTest < StablemateTest
  # A config whose environment and allow-list the test controls. The logger is a
  # sink: the registrar's own skip notices go through it, and they are not what
  # any test here is asserting on — the REPORT is.
  def configuration(environment: "production", environments: [ "production" ])
    config = Stablemate::Configuration.new
    config.environment = environment
    config.environments = environments
    config.logger = Logger.new(StringIO.new)
    config
  end

  # Pinned to the production section deliberately: the environment guard is the
  # thing under test in two of these, and a registrar that also moved would make
  # a passing run indistinguishable from a guard that never fired.
  def registrar(config, fixture_name)
    Stablemate::Registrars::SolidQueueRecurring.new(
      recurring_path: fixture(fixture_name), environment: "production", config:
    )
  end

  # The server's sync envelope. `monitors` is what registered; the rest is what
  # §6.1 requires the command to print.
  #
  # `ping_key_last4` is omitted unless a test asks for it, because that is the
  # shape a pre-§9.4 server sends and the guard has to stay silent on it.
  def envelope(registered: [], skipped: [], orphaned: [], retired: [], ping_key_last4: nil)
    { "monitors" => registered.map { |key| { "registration_key" => key, "status" => "pending" } },
      "skipped" => skipped.map { |key, reason| { "registration_key" => key, "reason" => reason } },
      "orphaned" => orphaned, "retired" => retired }
      .merge(ping_key_last4.nil? ? {} : { "ping_key_last4" => ping_key_last4 })
  end

  Run = Struct.new(:ok, :out, :err, :client, keyword_init: true)

  # Drives the real command over a fake client and captures BOTH streams, so a
  # test can assert on the report, the failure line and the request in one place.
  def run_sync(config: configuration, fixture_name: "recurring.yml", env: {}, client: nil, response: nil)
    # The real Registration builds its registrar FROM the config, so the two
    # always name the same file; keep the double honest about that, or a message
    # naming c.recurring_path reads as correct here and wrong in production.
    config.recurring_path = fixture(fixture_name)
    client ||= Stablemate::FakeClient.new(
      sync_response: response || envelope(registered: %w[daily_digest clear_sessions])
    )
    registration = Stablemate::Registration.new(
      registrar: registrar(config, fixture_name), client:, app: "my-app", config:
    )
    out = StringIO.new
    err = StringIO.new

    ok = Stablemate::Commands::Sync.new(config:, registration:, env:, out:, err:).sync!

    Run.new(ok:, out: out.string, err: err.string, client:)
  end

  # A file whose every task is unregisterable, which is §6.1's second
  # register-nothing path and cannot be built from the shipped fixtures.
  def only_command_tasks
    Tempfile.create([ "commands", ".yml" ]) do |file|
      file.write("production:\n  db_backup:\n    command: \"Backup.run\"\n    schedule: \"0 3 * * *\"\n")
      file.flush
      yield file.path
    end
  end

  # --- The environment guard (§6.1) ---------------------------------------

  # `enabled_in?` existed only in the railtie and the rake task never consulted
  # it, so a local run registered the DEVELOPMENT section into the production
  # project and exited 0. That was a nuisance while boot sync corrected it; now
  # whatever the last hand-run wrote is the entire monitor set.
  def test_refuses_to_run_outside_its_configured_environment
    run = run_sync(config: configuration(environment: "development"))

    refute run.ok, "a run outside c.environments must not report success"
    assert_empty run.client.synced, "the guard is FIRST (§3.1): no parse, no request"
    assert_match(/development/, run.err)
    assert_match(/production/, run.err)
    assert_match(/FORCE=1/, run.err)
  end

  def test_force_overrides_the_environment_guard
    run = run_sync(config: configuration(environment: "development"), env: { "FORCE" => "1" })

    assert run.ok
    refute_empty run.client.synced
  end

  # FORCE=0 must not mean "force" — which is what the bare ENV.key? check people
  # reach for would make it.
  def test_force_zero_does_not_force
    run = run_sync(config: configuration(environment: "development"), env: { "FORCE" => "0" })

    refute run.ok
    assert_empty run.client.synced
  end

  # A nil allow-list means "wherever a key is set" (Configuration#enabled_in?),
  # so the guard must not fire on a host that opted out of it.
  def test_a_nil_allow_list_permits_every_environment
    run = run_sync(config: configuration(environment: "staging", environments: nil))

    assert run.ok
  end

  # --- Exit non-zero when it registers nothing, four ways (§6.1) -----------

  def test_a_missing_recurring_file_registers_nothing_and_exits_non_zero
    run = run_sync(fixture_name: "missing.yml")

    refute run.ok
    assert_empty run.client.synced, "an empty parse must not even reach the request"
    assert_match(/synced 0/, run.out)
    assert_match(/#{Regexp.escape(fixture('missing.yml'))}/, run.err)
  end

  # The second parse-empty path, and the one that needs the report: "registered
  # nothing" is only actionable beside the reason nothing could be registered.
  def test_a_file_with_no_registerable_task_exits_non_zero_naming_the_skip
    only_command_tasks do |path|
      config = configuration
      client = Stablemate::FakeClient.new
      registration = Stablemate::Registration.new(
        registrar: Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: path, config:),
        client:, app: "my-app", config:
      )
      out = StringIO.new
      err = StringIO.new

      refute Stablemate::Commands::Sync.new(config:, registration:, env: {}, out:, err:).sync!
      assert_empty client.synced
      assert_match(/db_backup/, out.string)
      assert_match(/skipped/, out.string)
    end
  end

  # A free plan capped at five, six jobs declared: the run completes, the server
  # refuses every entry, and the old command printed `synced 0` and exited 0.
  def test_a_server_that_refuses_every_entry_exits_non_zero
    run = run_sync(response: envelope(skipped: [ [ "daily_digest", "limit_reached" ],
                                                 [ "clear_sessions", "limit_reached" ] ]))

    refute run.ok
    refute_empty run.client.synced, "the request WAS made — this is not a parse-empty run"
    assert_match(/daily_digest/, run.out)
    assert_match(/limit_reached/, run.out)
    assert_match(/synced 0/, run.out)
  end

  # The fourth path: a transport failure printed via `warn` and set no status at
  # all, so a deploy that reached nothing exited 0.
  def test_a_transport_failure_exits_non_zero
    failing = Object.new
    def failing.sync_monitors(**) = raise(Stablemate::Client::Error, "sync failed: 503")

    run = run_sync(client: failing)

    refute run.ok
    refute_empty run.err
  end

  # A billing limit must not fail a deploy: over-cap is a persistent state the
  # dashboard carries (§6.1), not a red build, so a run that registered SOMETHING
  # exits 0 with the refusal named.
  def test_an_over_cap_refusal_beside_a_success_still_exits_zero
    run = run_sync(response: envelope(registered: %w[daily_digest],
                                      skipped: [ [ "clear_sessions", "limit_reached" ] ]))

    assert run.ok
    assert_match(/clear_sessions/, run.out)
    assert_match(/limit_reached/, run.out)
  end

  # --- The count (§6.1's two traps) ---------------------------------------

  # `sync!` used to answer the process-wide address CACHE and the task printed
  # `cache.size` — never a per-run count.
  def test_prints_this_runs_count_and_the_environment
    run = run_sync(response: envelope(registered: %w[daily_digest clear_sessions]))

    assert_match(/synced 2 for environment 'production'/, run.out)
  end

  # `0.size` is 8. The trap is why §6.1 says the call must be REMOVED rather than
  # re-pointed at something else that answers to it.
  def test_a_run_that_registers_nothing_says_zero_not_eight
    run = run_sync(response: envelope)

    assert_match(/synced 0 /, run.out)
    refute_match(/synced 8/, run.out)
  end

  # --- One line per task, naming where the number came from (§6.1) ---------

  def test_a_derived_task_names_its_schedule
    run = run_sync(response: envelope(registered: %w[daily_digest clear_sessions]))

    assert_match(/daily_digest.*every 24h.*derived from 'every day at 9am'/, run.out)
    assert_match(/clear_sessions.*every 15m/, run.out)
  end

  # The line the whole rule exists for: an override is named INLINE, beside the
  # derived value it replaced, so the 72-hour weekday window is visible at the
  # moment the user can still fix it.
  def test_an_override_is_named_inline_with_the_value_it_replaced
    config = configuration
    config.overrides = { "daily_digest" => { interval: 93_600 } }

    run = run_sync(config:, response: envelope(registered: %w[daily_digest]))

    assert_match(/daily_digest.*every 26h.*override.*derived 24h from 'every day at 9am'/, run.out)
  end

  def test_a_declaration_says_it_came_from_c_monitors
    config = configuration
    config.monitors = { "pg_backup" => { interval: 86_400 } }

    run = run_sync(config:, response: envelope(registered: %w[daily_digest pg_backup]))

    assert_match(/pg_backup.*every 24h.*declared in c\.monitors/, run.out)
  end

  # A skip carries the REGISTRAR's reason — the fixture's command-only task,
  # which can never be auto-pinged and so is never sent.
  def test_a_registrar_skip_carries_its_reason
    run = run_sync

    assert_match(/db_backup.*skipped:.*command task/, run.out)
  end

  # --- Orphans and retirements (§6.1) -------------------------------------

  # Reported by default, and touched by nothing: the task was renamed or removed,
  # and a monitor that was live keeps monitoring until someone says otherwise.
  def test_orphans_are_named_with_their_remedy
    run = run_sync(response: envelope(registered: %w[daily_digest], orphaned: %w[old_report legacy_sync]))

    assert run.ok
    assert_match(/old_report/, run.out)
    assert_match(/legacy_sync/, run.out)
    assert_match(/PRUNE=1/, run.out)
  end

  # PRUNE=1 sends the flag AND declared_keys — every task key this run's
  # registrar can SEE before its skips, plus every c.monitors key. Without the
  # list the server retires nothing (a pre-0.2.0 gem), and with a list built from
  # the REGISTERED keys instead, a task whose class: line was deleted would be
  # retired: a YAML typo turned into monitoring-off for a live job.
  def test_prune_sends_the_flag_and_every_key_the_registrar_can_see
    config = configuration
    config.monitors = { "pg_backup" => { interval: 86_400 } }

    run = run_sync(config:, env: { "PRUNE" => "1" },
                   response: envelope(registered: %w[daily_digest], retired: %w[old_report]))

    posted = run.client.synced.first
    assert posted[:prune]
    # db_backup is a command task the registrar SKIPS — and it must still be
    # declared, or a prune run would retire the monitor of a job that is right
    # there in the file.
    assert_equal %w[daily_digest clear_sessions db_backup pg_backup].sort, posted[:declared_keys].sort
  end

  # The environment scoping has to be spelled out: "every key in recurring.yml"
  # read literally would also protect a key that exists only under ANOTHER
  # environment's section, and the two readings retire different monitors.
  def test_declared_keys_are_scoped_to_the_environments_section
    run = run_sync(fixture_name: "recurring_multi_env.yml", env: { "PRUNE" => "1" })

    keys = run.client.synced.first[:declared_keys]
    assert_includes keys, "daily_digest"
    refute_includes keys, "dev_smoke"
  end

  def test_a_run_without_prune_sends_neither_the_flag_nor_the_keys
    posted = run_sync.client.synced.first

    refute posted[:prune]
    assert_nil posted[:declared_keys]
  end

  # Retiring is a successful outcome (§6.1) — reversible, with history intact —
  # so it exits 0 and each retirement names its own remedy.
  def test_retirements_are_named_with_their_remedy
    run = run_sync(env: { "PRUNE" => "1" },
                   response: envelope(registered: %w[daily_digest clear_sessions], retired: %w[old_report]))

    assert run.ok
    assert_match(/retired old_report/, run.out)
    assert_match(/restore the task/, run.out)
  end

  # A prune run's `orphaned` list is the candidates it deliberately SPARED —
  # present in declared_keys but not registerable — so telling the operator to
  # "retire them with PRUNE=1" would be advice for a flag they just used.
  def test_a_spared_orphan_on_a_prune_run_is_not_told_to_use_prune
    run = run_sync(env: { "PRUNE" => "1" },
                   response: envelope(registered: %w[daily_digest], orphaned: %w[db_backup]))

    assert_match(/db_backup/, run.out)
    refute_match(/retire them with PRUNE=1/, run.out)
  end

  # The same orphan on a run WITHOUT the flag: db_backup is skipped by the
  # registrar, so it is still declared and a prune would deliberately spare it.
  # Recommending the flag sends the operator to run it, watch nothing happen,
  # and only then be told why.
  def test_an_orphan_whose_task_is_merely_unregisterable_is_not_told_to_use_prune
    run = run_sync(response: envelope(registered: %w[daily_digest clear_sessions], orphaned: %w[db_backup]))

    assert_match(/db_backup/, run.out)
    refute_match(/retire them with PRUNE=1/, run.out)
  end

  # Both remedies at once: one orphan whose task is gone, one whose task is
  # merely unregisterable. A single per-run sentence has to be wrong about one
  # of them.
  def test_orphans_are_grouped_by_which_remedy_applies
    run = run_sync(response: envelope(registered: %w[daily_digest clear_sessions],
                                      orphaned: %w[db_backup old_report]))

    lines = run.out.lines.map(&:chomp)
    named = lines[lines.index { |line| line.include?("PRUNE=1") } - 1]
    assert_includes named, "old_report"
    refute_includes named, "db_backup", "the flag would deliberately spare a still-declared task"
  end

  # A prune this run could not bound is a prune it must not send (see
  # RegistrationTest) — and the operator asked for one, so say so where they are
  # looking rather than only in the log.
  def test_a_dropped_prune_says_so_on_stdout
    config = configuration
    config.monitors = { "pg_backup" => { interval: 86_400 } }

    run = run_sync(config:, fixture_name: "missing.yml", env: { "PRUNE" => "1" },
                   response: envelope(registered: %w[pg_backup]))

    assert run.ok
    assert_match(/PRUNE/, run.out)
    assert_match(/#{Regexp.escape(fixture('missing.yml'))}/, run.out)
  end

  # The registrar's skip and the c.monitors entry that answers it are the same
  # key, and that skip's own message is the advice the user followed. Printing
  # both lines tells them their fix did not work.
  def test_a_declaration_that_rescues_a_skipped_task_prints_one_line
    config = configuration
    config.monitors = { "db_backup" => { interval: 86_400 } }

    run = run_sync(config:, response: envelope(registered: %w[daily_digest clear_sessions db_backup]))

    assert_match(/db_backup.*declared in c\.monitors/, run.out)
    refute_match(/db_backup.*skipped/, run.out)
  end

  # A YAML syntax error is a config error, not a transport one: the sync-failed
  # copy tells the operator to re-run, which will never help.
  def test_a_broken_recurring_file_names_the_file_rather_than_blaming_the_network
    Tempfile.create([ "broken", ".yml" ]) do |file|
      file.write("production:\n  daily_digest:\n   class: X\n    schedule: bad indent\n")
      file.flush
      config = configuration
      config.recurring_path = file.path
      client = Stablemate::FakeClient.new
      registration = Stablemate::Registration.new(
        registrar: Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: file.path, config:),
        client:, app: "my-app", config:
      )
      err = StringIO.new

      refute Stablemate::Commands::Sync.new(config:, registration:, env: {}, out: StringIO.new, err:).sync!
      assert_empty client.synced
      assert_match(/#{Regexp.escape(file.path)}/, err.string)
      refute_match(/re-run this command/, err.string)
    end
  end

  # --- The mismatch guard (§9.4) ------------------------------------------

  # A config whose ping key is set, since that is the credential under test here.
  def keyed_configuration(ping_key)
    configuration.tap { |config| config.ping_key = ping_key }
  end

  # Use project A's API key with project B's ping key and registration writes to
  # A while check-ins go to B: A's monitors go down permanently and every symptom
  # reads "your job is down". Impossible with one credential, permanent with two
  # — and this command is the only process that holds a registration response, so
  # it is the only place the two can be compared.
  def test_a_ping_key_from_another_project_is_called_out_loudly
    run = run_sync(config: keyed_configuration("sm_ping_somewhereelse"),
                   response: envelope(registered: %w[daily_digest], ping_key_last4: %w[ab12 cd34]))

    assert run.ok, "a warning, not a failure: the registration itself succeeded"
    assert_match(/ab12/, run.err)
    assert_match(/cd34/, run.err)
    assert_match(/ping key/i, run.err)
  end

  # A SET, not a value. §4's rotation deliberately keeps two keys live at once,
  # so a guard comparing against a single key would fire during exactly the
  # operation it exists to support.
  def test_no_warning_while_two_keys_are_live_and_the_configured_one_is_either
    %w[sm_ping_liveab12 sm_ping_livecd34].each do |key|
      run = run_sync(config: keyed_configuration(key),
                     response: envelope(registered: %w[daily_digest], ping_key_last4: %w[ab12 cd34]))

      refute_match(/ping key/i, run.err)
      assert_empty run.err
    end
  end

  # A pre-§9.4 server sends no such key. Absent means "this server cannot answer
  # the question", and warning on it would make every deploy against an older
  # Stablemate print a mismatch that may not exist.
  def test_a_server_that_reports_no_key_set_produces_no_warning
    run = run_sync(config: keyed_configuration("sm_ping_somewhereelse"),
                   response: envelope(registered: %w[daily_digest]))

    assert_empty run.err
  end

  # Present-but-empty is a different fact from absent: this project has no live
  # ping key at all, so the configured one belongs somewhere else (or was
  # revoked) and every check-in is 401ing.
  def test_an_empty_set_is_a_mismatch_rather_than_silence
    run = run_sync(config: keyed_configuration("sm_ping_somewhereelse"),
                   response: envelope(registered: %w[daily_digest], ping_key_last4: []))

    assert run.ok
    assert_match(/ping key/i, run.err)
  end

  # Nothing to compare, and a different problem with its own message: boot says
  # "check-ins are DISABLED" for this one (§6.5). Reporting it as a MISMATCH
  # would send the operator hunting for the wrong project.
  def test_no_configured_ping_key_is_not_reported_as_a_mismatch
    run = run_sync(response: envelope(registered: %w[daily_digest], ping_key_last4: %w[ab12]))

    assert_empty run.err
  end

  # The guard is bounded by the run, not by the registration: a run the server
  # refused wholesale still holds an envelope, and its operator is exactly the
  # one who needs to know their two credentials name different projects.
  def test_the_guard_fires_on_a_run_that_registered_nothing
    run = run_sync(config: keyed_configuration("sm_ping_somewhereelse"),
                   response: envelope(skipped: [ [ "daily_digest", "limit_reached" ] ],
                                      ping_key_last4: %w[ab12]))

    refute run.ok
    assert_match(/ab12/, run.err)
  end

  # A malformed envelope must not INVENT a mismatch: junk is unreadable, not
  # evidence of two projects, and a false alarm here sends someone rotating a
  # credential that was fine.
  def test_a_junk_key_set_is_ignored_rather_than_read_as_a_mismatch
    run = run_sync(config: keyed_configuration("sm_ping_somewhereelse"),
                   response: envelope(registered: %w[daily_digest]).merge("ping_key_last4" => "ab12"))

    assert_empty run.err
  end

  # --- Config errors (§3.1's pinned order) --------------------------------

  # An override typo must be reported even on a run that would go on to register
  # nothing, or the two errors mask each other — and it must exit non-zero
  # before any request is made.
  def test_an_unknown_override_key_exits_non_zero_naming_the_key
    config = configuration
    config.overrides = { "dailly_digest" => { interval: 93_600 } }

    run = run_sync(config:)

    refute run.ok
    assert_empty run.client.synced
    assert_match(/dailly_digest/, run.err)
  end

  def test_an_override_typo_is_reported_on_a_run_that_would_register_nothing
    config = configuration
    config.overrides = { "dailly_digest" => { interval: 93_600 } }

    run = run_sync(config:, fixture_name: "missing.yml")

    refute run.ok
    assert_match(/dailly_digest/, run.err)
  end

  # --- ABSOLUTE: sync's stdout is deploy logs (§6.1) -----------------------

  # An earlier revision printed the ready-to-paste `curl` block — which embeds
  # the live ping key — from this command, and sync runs from the post-deploy
  # hook, so that wrote a live credential into every CI run's log, forever. The
  # §6.6 install command prints it instead: an interactive dev-machine run whose
  # own invocation already carries the keys.
  #
  # Grepped rather than reasoned about, on every path including the failing ones,
  # because the regression is one refactor away from returning.
  def test_no_credential_ever_reaches_either_stream
    config = configuration
    config.api_key = "sm_live_0123456789abcdef0123"
    config.ping_key = "sm_ping_fedcba9876543210fedc"
    config.monitors = { "pg_backup" => { interval: 86_400 } }
    config.overrides = { "daily_digest" => { interval: 93_600 } }

    runs = [
      run_sync(config:, env: { "PRUNE" => "1" },
               response: envelope(registered: %w[daily_digest pg_backup],
                                  skipped: [ [ "clear_sessions", "limit_reached" ] ],
                                  orphaned: %w[old_report], retired: %w[legacy_sync])),
      run_sync(config: configuration(environment: "development").tap { |c| c.ping_key = config.ping_key }),
      run_sync(config:, client: raising_client(config.ping_key)),
      run_sync(config:, fixture_name: "missing.yml"),
      # §9.4's guard prints the last four characters of a live ping key on
      # purpose (that is the masked form the dashboard shows), so it is exactly
      # the line most likely to grow the rest of the credential by accident.
      run_sync(config:, response: envelope(registered: %w[daily_digest], ping_key_last4: %w[ab12]))
    ]

    runs.each do |run|
      refute_includes run.out, "sm_ping_"
      refute_includes run.out, "sm_live_"
      refute_includes run.err, "sm_ping_"
      refute_includes run.err, "sm_live_"
    end
  end

  # A transport error whose MESSAGE carries the credential — the shape a client
  # that interpolated a request into its error would produce. The command may
  # not relay it.
  def raising_client(ping_key)
    client = Object.new
    client.define_singleton_method(:sync_monitors) do |**|
      raise Stablemate::Client::Error, "connection refused (Authorization: Bearer #{ping_key})"
    end
    client
  end
end
