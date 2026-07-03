# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class SolidQueueRecurringTest < StablemateTest
  # environment is pinned explicitly: the fixtures are env-keyed and CI exports
  # RAILS_ENV=test, so relying on the default would diverge between local and CI.
  def registrar(file = "recurring.yml", environment: "production", config: Stablemate.config)
    Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture(file), environment:, config:)
  end

  # A config whose logger writes to the returned StringIO, for log assertions.
  def logging_config(out)
    config = Stablemate::Configuration.new
    config.logger = Logger.new(out)
    config
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

  # An env-keyed file yields only the CURRENT environment's tasks (matching
  # Solid Queue's own semantics) — a development-only task must never become a
  # monitor in the production account, where it would sit pending (eating a cap
  # slot) or false-alarm after a single stray ping.
  def test_env_keyed_file_yields_only_the_current_environments_tasks
    prod = registrar("recurring_multi_env.yml", environment: "production")
    dev = registrar("recurring_multi_env.yml", environment: "development")

    assert_equal [ "daily_digest" ], prod.tuples.map { |t| t[:registration_key] }
    assert_equal [ "dev_smoke" ], dev.tuples.map { |t| t[:registration_key] }
    assert_equal [ "DailyDigestJob" ], prod.class_to_keys.keys
  end

  def test_env_keyed_file_without_a_section_for_the_current_env_yields_nothing
    r = registrar("recurring_multi_env.yml", environment: "staging")
    assert_empty r.tuples
    assert_empty r.class_to_keys
  end
end
