# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class RegistrationTest < StablemateTest
  def registrar(config: Stablemate.config)
    Stablemate::Registrars::SolidQueueRecurring.new(
      recurring_path: fixture("recurring.yml"), environment: "production", config:
    )
  end

  # Scenario 24 — sync! posts to /api/v1/monitors/sync and answers with the
  # monitors the server registered. There is no ping-URL cache to fill any more
  # (§3.2): a check-in addresses itself by task key, so the response is read for
  # what it registered and refused, not for addresses.
  def test_sync_posts_tuples_and_returns_the_registered_monitors
    response = {
      "monitors" => [
        { "registration_key" => "daily_digest", "status" => "pending" },
        { "registration_key" => "clear_sessions", "status" => "pending" }
      ],
      "skipped" => []
    }
    client = Stablemate::FakeClient.new(sync_response: response)

    result = Stablemate::Registration.new(registrar:, client:, app: "my-app").sync!

    assert_equal 1, client.synced.size
    posted = client.synced.first
    assert_equal "my-app", posted[:app]
    # The fixture's command-only db_backup task is not registered (no class: to
    # attribute check-ins by), so only the two class-backed tasks are posted.
    assert_equal 2, posted[:monitors].size
    assert_equal %w[daily_digest clear_sessions], result.registered.map { |m| m["registration_key"] }
  end

  def test_sync_is_idempotent_across_runs
    response = { "monitors" => [ { "registration_key" => "daily_digest" } ], "skipped" => [] }
    client = Stablemate::FakeClient.new(sync_response: response)
    reg = Stablemate::Registration.new(registrar:, client:, app: "my-app")

    reg.sync!
    second = reg.sync!

    assert_equal 2, client.synced.size # posts each time
    assert_equal 1, second.count       # and answers per run, never accumulating
  end

  # §6.1 — sync! answers a RESULT, not the array of registered monitors and
  # certainly not the process-wide address cache the command used to print
  # `.size` on. #count is this run's count; the reasons ride along because the
  # command has to print them.
  def test_the_result_carries_this_runs_count_and_the_servers_reasons
    client = Stablemate::FakeClient.new(sync_response: {
      "monitors" => [ { "registration_key" => "daily_digest" } ],
      "skipped" => [ { "registration_key" => "clear_sessions", "reason" => "limit_reached" } ],
      "orphaned" => [ "old_report" ], "retired" => [ "legacy_sync" ]
    })

    result = Stablemate::Registration.new(registrar:, client:, app: "x", config: logging_config(StringIO.new)).sync!

    assert_equal 1, result.count
    assert result.registered?
    assert_equal [ { registration_key: "clear_sessions", reason: "limit_reached" } ], result.skipped
    assert_equal [ "old_report" ], result.orphaned
    assert_equal [ "legacy_sync" ], result.retired
  end

  # `{}` is truthy, so "the run completed and registered nothing" and "the run
  # did not complete" must be different objects or the command reports a
  # transport failure as an empty success (§6.1). A Result always means the
  # former; nil always means the latter.
  def test_a_run_that_registers_nothing_still_answers_a_result
    result = Stablemate::Registration.new(
      registrar: Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("missing.yml")),
      client: Stablemate::FakeClient.new, app: "x"
    ).sync!

    assert_equal 0, result.count
    refute result.registered?
  end

  # The registrars' own skips ride on the result too: on the register-nothing
  # paths they are the ONLY explanation of why nothing registered, and no
  # request was made to produce a server-side reason.
  def test_the_result_carries_the_registrars_skips
    result = Stablemate::Registration.new(
      registrar:, client: Stablemate::FakeClient.new, app: "x", config: logging_config(StringIO.new)
    ).sync!

    assert_equal [ "db_backup" ], result.skips.map { |skip| skip[:registration_key] }
    assert_match(/command/, result.skips.first[:reason])
  end

  # A malformed skipped entry must not cost the caller the reasons that ARE
  # well-formed, and must never reach the report as a nil key.
  def test_a_malformed_skip_is_normalised_rather_than_dropped_on_the_floor
    client = Stablemate::FakeClient.new(sync_response: {
      "monitors" => [ { "registration_key" => "daily_digest" } ], "skipped" => [ {} ]
    })

    result = Stablemate::Registration.new(registrar:, client:, app: "x", config: logging_config(StringIO.new)).sync!

    assert_equal [ { registration_key: "(unnamed)", reason: "no reason given" } ], result.skipped
  end

  # F9 — the server skips entries it won't register (over the account's monitor
  # cap, or a malformed tuple). A skipped job is silently UNMONITORED, which is
  # exactly what the registrar already refuses to let happen quietly when it
  # can't size a schedule. Warn per entry, with the task key and the reason.
  def test_skipped_entries_are_logged_with_key_and_reason
    response = {
      "monitors" => [ { "registration_key" => "daily_digest" } ],
      "skipped" => [
        { "registration_key" => "clear_sessions", "reason" => "limit_reached" },
        { "registration_key" => "db_backup", "reason" => "invalid" }
      ]
    }
    out = StringIO.new
    client = Stablemate::FakeClient.new(sync_response: response)

    registered = Stablemate::Registration.new(registrar:, client:, app: "x", config: logging_config(out)).sync!

    assert_match(/WARN.*clear_sessions/, out.string)
    assert_match(/limit_reached/, out.string)
    assert_match(/WARN.*db_backup/, out.string)
    assert_match(/invalid/, out.string)
    # The registered monitors still come back — reporting the skips is additive.
    assert_equal [ "daily_digest" ], registered.registered.map { |m| m["registration_key"] }
  end

  # No skips, no noise: a clean sync must stay silent, or the warning stops
  # meaning anything.
  def test_clean_sync_logs_nothing
    out = StringIO.new
    client = Stablemate::FakeClient.new(
      sync_response: { "monitors" => [ { "registration_key" => "daily_digest" } ] }
    )

    Stablemate::Registration.new(registrar:, client:, app: "x", config: logging_config(out)).sync!

    assert_empty out.string
  end

  # A malformed skipped list must not cost the caller its result: the command
  # still reports what was registered.
  def test_malformed_skipped_list_does_not_break_the_sync
    client = Stablemate::FakeClient.new(
      sync_response: { "monitors" => [ { "registration_key" => "daily_digest" } ],
                       "skipped" => [ "just-a-string", nil, {} ] }
    )

    registered = Stablemate::Registration.new(registrar:, client:, app: "x").sync!

    assert_equal [ "daily_digest" ], registered.registered.map { |m| m["registration_key"] }
  end

  # A sync failure logs a warning and never raises (returns nil).
  def test_sync_failure_is_swallowed
    failing = Object.new
    def failing.sync_monitors(**) = raise(Stablemate::Client::Error, "boom")

    result = Stablemate::Registration.new(registrar:, client: failing, app: "x").sync!
    assert_nil result
  end

  def test_empty_registrar_does_not_post
    empty = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("missing.yml"))
    client = Stablemate::FakeClient.new
    Stablemate::Registration.new(registrar: empty, client:, app: "x").sync!
    assert_empty client.synced
  end

  # --- §6.3, c.monitors: work that is not a Rails job, declared in the same
  # place and registered by the same command. Merged HERE and not in the
  # registrar, deliberately: fold it in there and `registrar.tuples` — the
  # may-register set the reportable allow-list is intersected against — starts
  # carrying keys that have no job class, so a declaration named after a host job
  # class would let that class check in for the shell script's monitor. ---

  def test_declarations_are_merged_into_the_payload
    Stablemate.config.monitors = { "pg_backup" => { interval: 86_400, grace: 7_200 } }
    client = Stablemate::FakeClient.new

    Stablemate::Registration.new(registrar:, client:, app: "my-app").sync!

    posted = client.synced.first[:monitors]
    assert_equal %w[daily_digest clear_sessions pg_backup], posted.map { |m| m[:registration_key] }
    backup = posted.last
    assert_equal 86_400, backup[:expected_interval_seconds]
    assert_equal 7_200, backup[:grace_period_seconds]
  end

  # The register-nothing short circuit reads the MERGED payload: a host with no
  # recurring.yml at all still registers its declarations, and posting nothing
  # here would mean every check-in from the backup script 404s forever.
  def test_declarations_register_without_a_recurring_file
    Stablemate.config.monitors = { "pg_backup" => { interval: 86_400 } }
    empty = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("missing.yml"))
    client = Stablemate::FakeClient.new

    Stablemate::Registration.new(registrar: empty, client:, app: "x").sync!

    assert_equal [ "pg_backup" ], client.synced.first[:monitors].map { |m| m[:registration_key] }
  end

  # The collision rule is about keys that REGISTER, which is why it is checked
  # against the tuples and not against every key in the file: declaring a
  # command-only task in c.monitors is the documented remedy for it (the
  # registrar skips it — nothing can auto-ping a SolidQueue::RecurringJob — and
  # the command pings itself). Comparing against the raw file instead would
  # reject exactly the fix we tell people to apply.
  def test_a_declaration_may_rescue_a_task_the_registrar_skipped
    Stablemate.config.monitors = { "db_backup" => { interval: 86_400 } }
    client = Stablemate::FakeClient.new

    Stablemate::Registration.new(registrar:, client:, app: "x").sync!

    backup = client.synced.first[:monitors].find { |m| m[:registration_key] == "db_backup" }
    assert_equal 86_400, backup[:expected_interval_seconds]
    refute_includes backup.keys, :schedule
  end

  # §6.3 — a declaration colliding with a recurring.yml task key used to resolve
  # last-wins with no warning. One key is one monitor, so the two declarations
  # fight over its interval and the winner depends on merge order.
  def test_a_declaration_colliding_with_a_task_key_fails_the_run
    Stablemate.config.monitors = { "daily_digest" => { interval: 86_400 } }
    client = Stablemate::FakeClient.new

    error = assert_raises(Stablemate::ConfigurationError) do
      Stablemate::Registration.new(registrar:, client:, app: "x").sync!
    end

    assert_match(/daily_digest/, error.message)
    assert_empty client.synced
  end

  # --- §3.1, c.overrides: the only remedy for a derived interval that is correct
  # and useless, now that the edit form is gone. ---

  def test_overrides_are_applied_to_the_payload
    Stablemate.config.overrides = { "daily_digest" => { interval: 93_600 } }
    client = Stablemate::FakeClient.new

    Stablemate::Registration.new(registrar:, client:, app: "x").sync!

    digest = client.synced.first[:monitors].find { |m| m[:registration_key] == "daily_digest" }
    assert_equal 93_600, digest[:expected_interval_seconds]
    # Recomputed from the OVERRIDDEN interval, not the schedule's.
    assert_equal (93_600 * 0.15).round, digest[:grace_period_seconds]
  end

  # §6.1's report names the derived value beside the override, so the entry has
  # to carry it — and the server has no business seeing it. The wire payload is
  # sliced to the five fields the server's entry struct reads, so a provenance
  # field cannot leak onto it by being forgotten.
  def test_provenance_rides_on_the_result_and_never_on_the_wire
    Stablemate.config.overrides = { "daily_digest" => { interval: 93_600 } }
    client = Stablemate::FakeClient.new

    result = Stablemate::Registration.new(registrar:, client:, app: "x").sync!

    entry = result.entries.find { |e| e[:registration_key] == "daily_digest" }
    assert_equal 86_400, entry[:derived_interval_seconds]
    posted = client.synced.first[:monitors].find { |m| m[:registration_key] == "daily_digest" }
    assert_equal %i[registration_key name expected_interval_seconds grace_period_seconds schedule].sort,
                 posted.keys.sort
  end

  # --- §6.1, PRUNE=1: the flag and the key list that bounds it ------------

  # `declared_keys` is every key this run's registrar can SEE before its skips,
  # plus every c.monitors key. Built from the REGISTERED keys instead, a task
  # whose class: line was deleted would be retired — a YAML typo turned into
  # monitoring-off for a live job.
  def test_a_prune_run_sends_the_flag_and_every_key_before_the_skips
    Stablemate.config.monitors = { "pg_backup" => { interval: 86_400 } }
    client = Stablemate::FakeClient.new

    Stablemate::Registration.new(registrar:, client:, app: "x").sync!(prune: true)

    posted = client.synced.first
    assert posted[:prune]
    assert_equal %w[clear_sessions daily_digest db_backup pg_backup], posted[:declared_keys].sort
  end

  def test_a_run_without_prune_sends_neither
    client = Stablemate::FakeClient.new

    Stablemate::Registration.new(registrar:, client:, app: "x").sync!

    refute client.synced.first[:prune]
    assert_nil client.synced.first[:declared_keys]
  end

  # The incident, reproduced in the one place §6.1 believed it had made
  # unreachable. The parse-empty exit is checked against the MERGED payload, so a
  # single c.monitors entry carries the run past it — and the prune then goes out
  # with a declared_keys naming only that entry, which is every recurring-derived
  # monitor absent from the list and therefore retired. A missing recurring.yml
  # (a mis-set path in the deploy container is the same shape) must drop the
  # flag, not send it with a short list.
  def test_a_prune_is_dropped_when_the_recurring_file_yielded_no_task
    Stablemate.config.monitors = { "pg_backup" => { interval: 86_400 } }
    empty = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("missing.yml"))
    client = Stablemate::FakeClient.new

    result = Stablemate::Registration.new(registrar: empty, client:, app: "x").sync!(prune: true)

    refute client.synced.first[:prune], "a prune bounded by an under-declared list retires everything"
    assert result.prune_suppressed?
    refute result.pruned?
  end

  # Worse than empty, and it slips through an emptiness check: when the current
  # environment has no section, Solid Queue's rule falls back to the whole file —
  # so on an env-keyed recurring.yml `declared_keys` becomes the SECTION NAMES.
  # Non-empty, plausible-looking, and containing none of the real task keys.
  def test_a_prune_is_dropped_when_the_section_resolved_to_other_environments
    Stablemate.config.monitors = { "pg_backup" => { interval: 86_400 } }
    staging = Stablemate::Registrars::SolidQueueRecurring.new(
      recurring_path: fixture("recurring_multi_env.yml"), environment: "staging"
    )
    client = Stablemate::FakeClient.new

    result = Stablemate::Registration.new(registrar: staging, client:, app: "x").sync!(prune: true)

    refute client.synced.first[:prune]
    assert result.prune_suppressed?
  end

  def test_a_prune_with_a_real_task_list_is_sent
    result = Stablemate::Registration.new(registrar:, client: Stablemate::FakeClient.new, app: "x",
                                          config: logging_config(StringIO.new)).sync!(prune: true)

    assert result.pruned?
    refute result.prune_suppressed?
  end

  # A YAML syntax error will not fix itself on the next deploy, so it must not be
  # reported as a sync failure ("re-run this command") — the exact treatment
  # ConfigurationError exists to keep it out of.
  def test_a_broken_recurring_file_is_a_config_error_not_a_sync_failure
    Tempfile.create([ "broken", ".yml" ]) do |file|
      file.write("production:\n  daily_digest:\n   class: X\n    schedule: bad indent\n")
      file.flush
      broken = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: file.path, environment: "production")

      error = assert_raises(Stablemate::ConfigurationError) do
        Stablemate::Registration.new(registrar: broken, client: Stablemate::FakeClient.new, app: "x").sync!
      end

      assert_match(/#{Regexp.escape(file.path)}/, error.message)
    end
  end

  # §3.1 — an override key matching no derived task fails the whole run, before
  # any request is made: half-applying the rest would make the failure ambiguous,
  # and a silently ignored typo leaves the job wearing the window the override
  # existed to correct. It also has to escape sync!'s rescue, which turns a
  # transport failure into a warning — a config error will not fix itself on the
  # next deploy.
  def test_an_unknown_override_key_fails_the_run_before_any_request
    Stablemate.config.overrides = { "dailly_digest" => { interval: 93_600 } }
    client = Stablemate::FakeClient.new

    error = assert_raises(Stablemate::ConfigurationError) do
      Stablemate::Registration.new(registrar:, client:, app: "x").sync!
    end

    assert_match(/dailly_digest/, error.message)
    assert_empty client.synced
  end

  # §6.1's order: parse, then override validation, then the register-nothing
  # exits. Validating after the short circuit would mask the typo on exactly the
  # run that is already going wrong.
  def test_an_override_typo_is_reported_on_a_run_that_would_register_nothing
    Stablemate.config.overrides = { "dailly_digest" => { interval: 93_600 } }
    empty = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("missing.yml"))

    assert_raises(Stablemate::ConfigurationError) do
      Stablemate::Registration.new(registrar: empty, client: Stablemate::FakeClient.new, app: "x").sync!
    end
  end

  # --- #preview: what a sync WOULD send, without sending it (§6.6) ----------

  # `stablemate:install` is dry-run by design, and this is what makes that
  # affordable: the same payload the same code would post, computed and handed
  # back with no request made.
  def test_preview_computes_the_payload_and_makes_no_request
    client = Stablemate::FakeClient.new

    result = Stablemate::Registration.new(registrar:, client:, app: "x").preview

    assert_empty client.synced, "install registers nothing (§6.6)"
    assert_equal %w[daily_digest clear_sessions], result.entries.map { |e| e[:registration_key] }
    assert_equal [ "db_backup" ], result.skips.map { |skip| skip[:registration_key] }
    assert_equal 0, result.count, "nothing registered, because nothing was sent"
  end

  # A config error is a config error whether or not this run intended to register
  # anything — and install is the first place a typo in a fresh initializer can
  # be caught at all, which is a deploy cheaper than finding it in a hook.
  def test_preview_raises_a_config_error_like_a_real_run
    config = logging_config(StringIO.new)
    config.overrides = { "dailly_digest" => { interval: 93_600 } }

    error = assert_raises(Stablemate::ConfigurationError) do
      Stablemate::Registration.new(registrar: registrar(config:), client: Stablemate::FakeClient.new,
                                   app: "x", config:).preview
    end

    assert_match(/dailly_digest/, error.message)
  end

  # §3.1 — "derived" means AFTER the registrar's skips. A command-only task never
  # produces a tuple, so there is no monitor to override; overriding it would
  # read as configuring monitoring for a job that has none.
  def test_an_override_on_a_command_task_fails_the_run
    config = logging_config(StringIO.new)
    config.overrides = { "db_backup" => { interval: 93_600 } }
    client = Stablemate::FakeClient.new

    error = assert_raises(Stablemate::ConfigurationError) do
      Stablemate::Registration.new(registrar: registrar(config:), client:, app: "x", config:).sync!
    end

    assert_match(/db_backup/, error.message)
    assert_empty client.synced
  end

  # The other skip, and the one an override looks most like a fix for: a schedule
  # whose interval cannot be derived registers nothing, so there is nothing to
  # override — the remedy is a schedule Fugit can size, or a c.monitors entry.
  def test_an_override_on_an_underivable_schedule_fails_the_run
    config = logging_config(StringIO.new)
    config.overrides = { "impossible_date" => { interval: 93_600 } }
    underivable = Stablemate::Registrars::SolidQueueRecurring.new(
      recurring_path: fixture("recurring_underivable.yml"), environment: "production", config:
    )
    client = Stablemate::FakeClient.new

    error = assert_raises(Stablemate::ConfigurationError) do
      Stablemate::Registration.new(registrar: underivable, client:, app: "x", config:).sync!
    end

    assert_match(/impossible_date/, error.message)
    assert_empty client.synced
  end
end
