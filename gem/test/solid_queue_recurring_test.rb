# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class SolidQueueRecurringTest < StablemateTest
  def registrar(file = "recurring.yml")
    Stablemate::Registrars::SolidQueueRecurring.new(recurring_path: fixture(file))
  end

  # Scenario 21 — one tuple per task; registration_key == task key; interval via Fugit.
  def test_produces_one_tuple_per_task_keyed_by_task_key
    tuples = registrar.tuples
    keys = tuples.map { |t| t[:registration_key] }

    assert_equal 3, tuples.size
    assert_equal %w[daily_digest clear_sessions db_backup].sort, keys.sort

    digest = tuples.find { |t| t[:registration_key] == "daily_digest" }
    assert_equal "daily_digest", digest[:name]
    assert_equal 86_400, digest[:expected_interval_seconds]

    sessions = tuples.find { |t| t[:registration_key] == "clear_sessions" }
    assert_equal 900, sessions[:expected_interval_seconds]
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
end
