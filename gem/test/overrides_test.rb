# frozen_string_literal: true

require_relative "test_helper"

class OverridesTest < StablemateTest
  # A weekday-only cron derives 72 hours (Friday → Monday, §3.1) and a daily one
  # 24: the pair a real override run is applied to.
  def derived
    [
      { registration_key: "weekday_report", name: "weekday_report",
        expected_interval_seconds: 259_200, grace_period_seconds: 38_880, schedule: "0 9 * * 1-5" },
      { registration_key: "daily_digest", name: "daily_digest",
        expected_interval_seconds: 86_400, grace_period_seconds: 12_960, schedule: "0 9 * * *" }
    ]
  end

  def overrides(declared)
    config = Stablemate::Configuration.new
    config.overrides = declared
    Stablemate::Overrides.new(config:)
  end

  def apply(declared, tuples = derived, declared_keys: [])
    overrides(declared).apply_to(tuples, declared_keys:)
  end

  # §3.1 — the whole point: the derived interval is correct by construction and
  # useless (nothing is wrong until Monday), and with the edit form gone this is
  # the only remedy.
  def test_an_interval_override_replaces_the_derived_interval
    weekday = apply({ "weekday_report" => { interval: 93_600 } })
              .find { |t| t[:registration_key] == "weekday_report" }

    assert_equal 93_600, weekday[:expected_interval_seconds]
  end

  # §3.1's grace rule: grace is derived FROM the interval, so an interval-only
  # override recomputes it from the OVERRIDDEN interval. Anything else leaves a
  # 26-hour override wearing a 72-hour schedule's grace — a 10.8-hour window on a
  # 26-hour monitor, which is most of the blind spot the override was closing.
  def test_an_interval_override_recomputes_grace_from_the_overridden_interval
    weekday = apply({ "weekday_report" => { interval: 93_600 } })
              .find { |t| t[:registration_key] == "weekday_report" }

    assert_equal (93_600 * 0.15).round, weekday[:grace_period_seconds]
    refute_equal 38_880, weekday[:grace_period_seconds]
  end

  def test_an_explicit_grace_wins_over_the_recomputation
    weekday = apply({ "weekday_report" => { interval: 93_600, grace: 60 } })
              .find { |t| t[:registration_key] == "weekday_report" }

    assert_equal 93_600, weekday[:expected_interval_seconds]
    assert_equal 60, weekday[:grace_period_seconds]
  end

  def test_a_grace_only_override_keeps_the_derived_interval
    weekday = apply({ "weekday_report" => { grace: 3_600 } })
              .find { |t| t[:registration_key] == "weekday_report" }

    assert_equal 259_200, weekday[:expected_interval_seconds]
    assert_equal 3_600, weekday[:grace_period_seconds]
  end

  # The schedule string is "the string the interval was derived from" and stays
  # true of the task after an override — §6.1's output line names both ("every
  # 26h (override — derived 72h from '0 9 * * 1-5')"), so the string has to
  # survive the override that supersedes it.
  def test_an_overridden_tuple_keeps_its_schedule_string
    weekday = apply({ "weekday_report" => { interval: 93_600 } })
              .find { |t| t[:registration_key] == "weekday_report" }

    assert_equal "0 9 * * 1-5", weekday[:schedule]
  end

  def test_tuples_without_an_override_are_untouched
    tuples = derived
    digest = apply({ "weekday_report" => { interval: 93_600 } }, tuples)
             .find { |t| t[:registration_key] == "daily_digest" }

    assert_equal 86_400, digest[:expected_interval_seconds]
    assert_equal 12_960, digest[:grace_period_seconds]
    # And the registrar's own tuples are not edited underneath it: the CLI has to
    # print the derived value beside the override ("derived 72h from …").
    assert_equal 259_200, tuples.first[:expected_interval_seconds]
  end

  def test_no_overrides_returns_the_tuples_as_they_are
    assert_equal derived, apply({})
  end

  # §3.1 — a typo'd key silently ignored means the weekday job keeps its 72-hour
  # window, the exact failure overrides exist to close. Fail the whole run and
  # name the key.
  def test_an_override_matching_no_derived_task_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      apply({ "weekday_reprot" => { interval: 93_600 } })
    end

    assert_match(/weekday_reprot/, error.message)
  end

  # The same error on a run that derived nothing at all — the two failures must
  # not mask each other (§6.1's order: override validation BEFORE the
  # register-nothing exits).
  def test_an_override_is_validated_even_when_nothing_was_derived
    error = assert_raises(Stablemate::ConfigurationError) do
      apply({ "weekday_report" => { interval: 93_600 } }, [])
    end

    assert_match(/weekday_report/, error.message)
  end

  # §3.1 — overrides apply to DERIVED tasks only. A c.monitors entry carries its
  # own interval, so there is nothing to override: you would simply edit the
  # declaration. Named separately because "matches no derived task" would send
  # the user hunting through recurring.yml for a key that is in their initializer.
  def test_an_override_on_a_c_monitors_key_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      apply({ "pg_backup" => { interval: 93_600 } }, derived, declared_keys: [ "pg_backup" ])
    end

    assert_match(/pg_backup/, error.message)
    assert_match(/c\.monitors/, error.message)
  end

  # §3.1 — "an unknown key inside the hash is the same config error as an unknown
  # task key", or `intervall:` gets exactly the silent-typo treatment the outer
  # rule exists to close.
  def test_an_unknown_setting_inside_an_override_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      apply({ "weekday_report" => { intervall: 93_600 } })
    end

    assert_match(/weekday_report/, error.message)
    assert_match(/intervall/, error.message)
  end

  def test_string_setting_keys_are_accepted
    weekday = apply({ "weekday_report" => { "interval" => 93_600 } })
              .find { |t| t[:registration_key] == "weekday_report" }

    assert_equal 93_600, weekday[:expected_interval_seconds]
  end

  # Integer seconds are the canonical unit (§3.1), and "26 hours".to_i is 26 — a
  # 26-SECOND window, silently.
  def test_a_string_interval_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      apply({ "weekday_report" => { interval: "26 hours" } })
    end

    assert_match(/weekday_report/, error.message)
  end

  def test_a_non_hash_override_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) { apply({ "weekday_report" => 93_600 }) }

    assert_match(/weekday_report/, error.message)
  end
end
