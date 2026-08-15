# frozen_string_literal: true

require_relative "test_helper"
# 1.day: the unit a Rails host will reach for however loudly seconds are
# documented, and an ActiveSupport::Duration is what the cast below has to
# accept. Loaded here rather than doubled, so the test pins the real class.
require "active_support/core_ext/numeric/time"

class DeclaredMonitorsTest < StablemateTest
  def declared(monitors)
    config = Stablemate::Configuration.new
    config.monitors = monitors
    Stablemate::Registrars::DeclaredMonitors.new(config:)
  end

  # §6.3 — the translation, which is the whole point of this class. The server's
  # entry struct reads registration_key / name / expected_interval_seconds /
  # grace_period_seconds; `{ interval:, grace: }` matches NONE of them and has no
  # key field at all, so an untranslated entry is silently dropped: sync reports
  # success and every check-in against it 404s forever.
  def test_translates_a_declaration_into_the_servers_tuple_shape
    tuple = declared("pg_backup" => { interval: 86_400, grace: 7_200 }).tuples.first

    assert_equal({ registration_key: "pg_backup", name: "pg_backup",
                   expected_interval_seconds: 86_400, grace_period_seconds: 7_200 }, tuple)
  end

  # §6.3 — "entries declared with a bare interval have no schedule and send none".
  # The column means "the string the interval was derived from", never a promise,
  # so inventing one for a shell script would make it a lie.
  def test_a_declaration_sends_no_schedule
    tuple = declared("pg_backup" => { interval: 86_400 }).tuples.first

    refute_includes tuple.keys, :schedule
  end

  # Defaulted the way the registrar defaults it, so an entry that omits grace
  # behaves like a recurring.yml task instead of getting zero grace and
  # false-alarming on the first run that is a second late.
  def test_grace_defaults_the_way_the_registrar_defaults_it
    daily = declared("pg_backup" => { interval: 86_400 }).tuples.first
    frequent = declared("heartbeat" => { interval: 600 }).tuples.first

    assert_equal (86_400 * 0.15).round, daily[:grace_period_seconds]
    assert_equal 300, frequent[:grace_period_seconds] # 15% of 10m, floored to 5m
  end

  # Seconds are canonical because the gem supports a plain-Ruby host, but a Rails
  # host writes 1.day — and a Duration is only a Numeric because it says so.
  # Normalised to integer seconds here rather than left to survive JSON as the
  # numeric string its #to_s produces.
  def test_accepts_an_active_support_duration_as_integer_seconds
    tuple = declared("pg_backup" => { interval: 1.day, grace: 2.hours }).tuples.first

    assert_equal 86_400, tuple[:expected_interval_seconds]
    assert_equal 7_200, tuple[:grace_period_seconds]
  end

  # An initializer is Ruby, so both key styles turn up. Lenient about the key's
  # TYPE, strict about its name (below) — the strictness is there to catch typos,
  # not to pick a hash style.
  def test_string_setting_keys_are_accepted
    tuple = declared("pg_backup" => { "interval" => 86_400 }).tuples.first

    assert_equal 86_400, tuple[:expected_interval_seconds]
  end

  # §6.3's hard rule, made structural rather than remembered: these keys have no
  # job class by definition, so this source contributes NOTHING to the
  # class -> keys map. A key that happens to equal a host job class name
  # therefore cannot bind that class to a shell script's monitor — which would
  # let an unrelated Rails job advance it and read green while the backup has
  # been failing.
  def test_contributes_nothing_to_the_reportable_map
    source = declared("DailyDigestJob" => { interval: 86_400 })

    assert_empty source.class_to_keys
    assert_empty source.reportable_class_to_keys
  end

  def test_no_declarations_yields_no_tuples
    assert_empty declared({}).tuples
  end

  # Not merely skipped: an entry that can't be translated registers nothing while
  # sync still reports success, so every check-in from the work itself 404s
  # forever. Fail the run and name the key.
  def test_an_entry_with_no_interval_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      declared("pg_backup" => { grace: 7_200 }).tuples
    end

    assert_match(/pg_backup/, error.message)
    assert_match(/interval/, error.message)
  end

  # "1 day".to_i is 1, so a stray string would quietly register a ONE-SECOND
  # window and page the user on every run forever.
  def test_a_string_interval_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      declared("pg_backup" => { interval: "1 day" }).tuples
    end

    assert_match(/pg_backup/, error.message)
  end

  def test_a_non_positive_interval_is_a_config_error
    assert_raises(Stablemate::ConfigurationError) { declared("pg_backup" => { interval: 0 }).tuples }
  end

  # The same silent-typo rule §3.1 pins for c.overrides: `intervall:` must not be
  # read as "no interval given".
  def test_an_unknown_setting_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) do
      declared("pg_backup" => { interval: 86_400, intervall: 3_600 }).tuples
    end

    assert_match(/pg_backup/, error.message)
    assert_match(/intervall/, error.message)
  end

  def test_a_non_hash_declaration_is_a_config_error
    error = assert_raises(Stablemate::ConfigurationError) { declared("pg_backup" => 86_400).tuples }

    assert_match(/pg_backup/, error.message)
  end

  # §6.1 — a c.monitors key is as declared as a recurring.yml task, so a PRUNE=1
  # run must send it too or the server retires the shell script's monitor on the
  # first run where the entry is momentarily unregisterable.
  def test_declared_keys_are_every_declaration
    assert_equal %w[pg_backup restic_snapshot],
                 declared("pg_backup" => { interval: 86_400 }, "restic_snapshot" => { interval: 3_600 }).declared_keys
  end

  # Symbol keys are what an initializer written by hand actually contains, and
  # the server compares strings.
  def test_declared_keys_are_strings
    assert_equal [ "pg_backup" ], declared(pg_backup: { interval: 86_400 }).declared_keys
  end
end
