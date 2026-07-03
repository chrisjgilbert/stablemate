# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class SolidQueueRecurringTest < StablemateTest
  # environment is pinned explicitly: the fixtures are env-keyed and CI exports
  # RAILS_ENV=test, so relying on the default would diverge between local and CI.
  def registrar(file = "recurring.yml", environment: "production", config: Stablemate.config)
    Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture(file), environment:, config:)
  end

  # Scenario 21 — one tuple per class-backed task; registration_key == task key;
  # interval via Fugit. The command-only db_backup task is NOT registered (see
  # test_command_only_task_is_skipped_with_a_warning).
  def test_produces_one_tuple_per_task_keyed_by_task_key
    tuples = registrar.tuples
    keys = tuples.map { |t| t[:registration_key] }

    assert_equal 2, tuples.size
    assert_equal %w[daily_digest clear_sessions].sort, keys.sort

    digest = tuples.find { |t| t[:registration_key] == "daily_digest" }
    assert_equal "daily_digest", digest[:name]
    assert_equal 86_400, digest[:expected_interval_seconds]

    sessions = tuples.find { |t| t[:registration_key] == "clear_sessions" }
    assert_equal 900, sessions[:expected_interval_seconds]
  end

  # A command:-only task runs as SolidQueue::RecurringJob, so the execution
  # subscriber (keyed by job class name) can never ping it. Registering it would
  # create a monitor that is permanently down — skip it, and log (INFO: command
  # tasks are routine, e.g. Solid Queue's own housekeeping) so the operator knows
  # the job is unmonitored.
  def test_command_only_task_is_skipped_with_a_log_notice
    out = StringIO.new
    r = registrar(config: logging_config(out))

    refute_includes r.tuples.map { |t| t[:registration_key] }, "db_backup"
    assert_match(/INFO/, out.string)
    assert_match(/db_backup/, out.string)
    assert_match(/command/, out.string)
  end

  # A blank class: (e.g. templating that rendered empty) is as unpingable as a
  # missing one — the subscriber can never resolve a job class of "". Same skip.
  def test_blank_class_task_is_skipped_like_a_command_task
    Tempfile.create([ "blank", ".yml" ]) do |f|
      f.write("broken:\n  class: \"\"\n  command: \"Backup.run\"\n  schedule: every day at 3am\n")
      f.flush
      out = StringIO.new
      r = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path, config: logging_config(out))

      assert_empty r.tuples
      refute r.class_to_keys.key?("")
      assert_match(/broken/, out.string)
    end
  end

  # Scenario 22 — irregular cron -> the LARGEST gap is the interval.
  def test_irregular_cron_uses_the_largest_gap
    tuples = registrar("recurring_irregular.yml").tuples
    interval = tuples.first[:expected_interval_seconds]

    # 9am & 5pm -> gaps of 8h (9->17) and 16h (17->9 next day). Largest = 16h.
    assert_equal 16 * 3600, interval
  end

  # Scenario 23 — grace default = max(interval * fraction, 5 minutes).
  def test_grace_defaults_to_fraction_with_a_five_minute_floor
    tuples = registrar.tuples
    digest = tuples.find { |t| t[:registration_key] == "daily_digest" }
    sessions = tuples.find { |t| t[:registration_key] == "clear_sessions" }

    # daily: 86400 * 0.15 = 12960 (> 5m floor).
    assert_equal (86_400 * 0.15).round, digest[:grace_period_seconds]
    # 15m: 900 * 0.15 = 135 -> floored to 300 (5 minutes).
    assert_equal 300, sessions[:grace_period_seconds]
  end

  # Scenario 25 — class -> task_key map from recurring.yml.
  def test_builds_class_to_keys_map
    map = registrar.class_to_keys
    assert_equal [ "daily_digest" ], map["DailyDigestJob"]
    assert_equal [ "clear_sessions" ], map["ClearSessionsJob"]
    # command-only task has no class -> not in the map.
    refute map.key?("db_backup")
  end

  # Scenario 26 — two tasks sharing a job class map to both keys.
  def test_shared_job_class_maps_to_all_task_keys
    map = registrar("recurring_shared_class.yml").class_to_keys
    assert_equal %w[morning_report evening_report].sort, map["ReportJob"].sort
  end

  def test_missing_file_yields_no_tuples
    r = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture("does_not_exist.yml"))
    assert_empty r.tuples
  end

  def test_flat_file_without_environment_keys_is_supported
    Tempfile.create([ "flat", ".yml" ]) do |f|
      f.write("nightly:\n  class: NightlyJob\n  schedule: every day at 2am\n")
      f.flush
      r = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path)
      assert_equal [ "nightly" ], r.tuples.map { |t| t[:registration_key] }
    end
  end

  # A file with a section for the current environment yields ONLY that
  # section's tasks (Solid Queue's exact rule: `config[env] ? config[env] :
  # config`) — a development-only task must never become a monitor in the
  # production account, where it would sit pending (eating a cap slot) or
  # false-alarm after a single stray ping.
  def test_env_keyed_file_yields_only_the_current_environments_tasks
    prod = registrar("recurring_multi_env.yml", environment: "production")
    dev = registrar("recurring_multi_env.yml", environment: "development")

    assert_equal [ "daily_digest" ], prod.tuples.map { |t| t[:registration_key] }
    assert_equal [ "dev_smoke" ], dev.tuples.map { |t| t[:registration_key] }
    assert_equal [ "DailyDigestJob" ], prod.class_to_keys.keys
  end

  # No section for the current env -> Solid Queue falls back to the WHOLE file;
  # the other envs' sections then look like tasks without class:/schedule: and
  # are skipped, so nothing registers — but never crashes.
  def test_env_keyed_file_without_a_section_for_the_current_env_yields_nothing
    r = registrar("recurring_multi_env.yml", environment: "staging")
    assert_empty r.tuples
    assert_empty r.class_to_keys
  end

  # A mixed file (top-level tasks + an env section) must match Solid Queue: in
  # an env WITH a section, only the section's tasks run, so only they register;
  # in an env WITHOUT one, the whole file is used and the top-level tasks run.
  # Registering top-level tasks in production would create monitors Solid Queue
  # never pings — permanent false alarms.
  def test_mixed_file_follows_solid_queue_section_precedence
    Tempfile.create([ "mixed", ".yml" ]) do |f|
      f.write(<<~YML)
        stray_task:
          class: StrayJob
          schedule: every hour
        production:
          daily_digest:
            class: DailyDigestJob
            schedule: every day at 9am
      YML
      f.flush

      prod = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path, environment: "production")
      dev = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path, environment: "development")

      assert_equal [ "daily_digest" ], prod.tuples.map { |t| t[:registration_key] }
      assert_equal [ "stray_task" ], dev.tuples.map { |t| t[:registration_key] }
    end
  end

  # Degenerate sections must never crash boot: an explicitly empty section
  # (`development: {}`) yields nothing in that env, and a nil section
  # (`development:`) falls back to the whole file, Solid Queue-style.
  def test_empty_and_nil_sections_are_handled_without_crashing
    Tempfile.create([ "degenerate", ".yml" ]) do |f|
      f.write("production:\n  daily:\n    class: DailyJob\n    schedule: every day\ndevelopment: {}\nstaging:\n")
      f.flush

      { "production" => [ "daily" ], "development" => [], "staging" => [] }.each do |env, expected|
        r = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path, environment: env)
        assert_equal expected, r.tuples.map { |t| t[:registration_key] }, "environment #{env}"
        r.class_to_keys # must not raise on section-shaped or nil pseudo-tasks
      end
    end
  end

  # Scalar garbage where a task hash should be (bad indentation, templating
  # accidents) is skipped, not crashed on.
  def test_non_hash_task_entries_are_skipped
    Tempfile.create([ "garbage", ".yml" ]) do |f|
      f.write("nightly:\n  class: NightlyJob\n  schedule: every day at 2am\nbroken: just-a-string\nempty:\n")
      f.flush
      r = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path)

      assert_equal [ "nightly" ], r.tuples.map { |t| t[:registration_key] }
      assert_equal({ "NightlyJob" => [ "nightly" ] }, r.class_to_keys)
    end
  end

  # tuples + class_to_keys are both called on every boot; the file is read and
  # parsed once per registrar instance, not once per call.
  def test_recurring_file_is_parsed_once_per_registrar
    Tempfile.create([ "memo", ".yml" ]) do |f|
      f.write("nightly:\n  class: NightlyJob\n  schedule: every day at 2am\n")
      f.flush
      r = Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: f.path)
      refute_empty r.tuples

      File.write(f.path, "changed:\n  class: OtherJob\n  schedule: every hour\n")
      assert_equal({ "NightlyJob" => [ "nightly" ] }, r.class_to_keys)
    end
  end

  # The registrar defaults its environment to the shared Configuration#environment
  # resolver, so the railtie gate and the file scoping can never disagree.
  def test_environment_defaults_to_the_configurations_environment
    config = Stablemate::Configuration.new
    config.environment = "development"
    r = Stablemate::Registrars::SolidQueueRecurring.new(
      recurring_path: fixture("recurring_multi_env.yml"), config: config
    )

    assert_equal [ "dev_smoke" ], r.tuples.map { |t| t[:registration_key] }
  end
end
