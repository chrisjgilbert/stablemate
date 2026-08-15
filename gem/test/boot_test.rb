# frozen_string_literal: true

require_relative "test_helper"
require "stablemate/boot"
# active_support before its notifications: instrument reaches for
# ActiveSupport::IsolatedExecutionState, which the notifications file alone
# does not load.
require "active_support"
require "active_support/notifications"
require "tempfile"

# §6.5 — what boot does now: attach the check-in listener, and nothing else.
# No sync, no fetch, no cache. The three §12 boot cases live here (no ping key /
# ping key but no API key / broken recurring.yml), plus the two gates whose
# ORDER matters.
class BootTest < StablemateTest
  def setup
    super
    @logger = Stablemate::RecordingLogger.new
    @client = Stablemate::FakeClient.new
    Stablemate.config.logger = @logger
    # The allow-list defaults to production only, so every wiring test has to
    # say which environment it is booting in.
    Stablemate.config.environment = "production"
    Stablemate.config.ping_key = "sm_ping_test"
    Stablemate.config.recurring_path = fixture("recurring.yml")
  end

  def teardown
    # The listener is a process-global subscription; leaving one attached would
    # bleed check-ins into every later test.
    @wired&.unsubscribe!
    super
  end

  # dispatcher: the check-in would otherwise land on a background thread, and
  # these tests assert on what did NOT happen.
  def wire(**options)
    @wired = Stablemate::Boot.new(client: @client, dispatcher: SYNC_DISPATCHER, **options).wire!
  end

  # A stand-in ActiveJob instance, as in subscriber_test.
  def job(class_name)
    klass = Class.new do
      def job_id = @job_id ||= "fake-job-#{object_id}"
    end
    klass.define_singleton_method(:name) { class_name }
    klass.new
  end

  def perform(class_name)
    ActiveSupport::Notifications.instrument("perform.active_job", job: job(class_name)) { :ok }
  end

  # §12 — with a ping key and NO api key the listener is still attached and
  # check-ins work: boot has no use for the API key any more, and demanding one
  # would leave a correctly-configured host silently unmonitored.
  def test_attaches_the_listener_with_a_ping_key_and_no_api_key
    Stablemate.config.api_key = nil

    assert wire, "boot returned no subscriber"

    perform("DailyDigestJob")
    assert_equal [ "daily_digest" ], @client.pinged
    assert_empty @logger.errors
  end

  # Boot attaches the listener and does NOTHING else — registration is
  # `bin/rails stablemate:sync` now. A boot that still posted would re-introduce
  # the every-boot upsert of recurring.yml.
  def test_boot_registers_nothing
    wire

    assert_empty @client.synced
  end

  # §6.3 at the boot seam: the map handed to the subscriber is the REPORTABLE
  # one, so a task the registrar refuses to register (its schedule can't be
  # sized) can never check in — there is no monitor for it, and every run would
  # 404 forever.
  def test_the_wired_map_excludes_a_task_whose_schedule_cannot_be_sized
    Stablemate.config.recurring_path = fixture("recurring_underivable.yml")
    wire

    perform("ImpossibleDateJob")
    assert_empty @client.pinged

    perform("DailyDigestJob")
    assert_equal [ "daily_digest" ], @client.pinged
  end

  # §12 — no ping key: ONE error line, no listener, and the app still boots.
  def test_no_ping_key_logs_one_error_and_attaches_nothing
    Stablemate.config.ping_key = nil

    assert_nil wire
    assert_nil Stablemate.execution_subscriber

    assert_equal 1, @logger.errors.size
    assert_match(/no ping_key/, @logger.errors.first)
    assert_match(/DISABLED/, @logger.errors.first)
  end

  # `.presence`, not truthiness: a set-but-empty STABLEMATE_PING_KEY is "",
  # which is truthy — the gate would pass and every check-in would carry
  # `Authorization: Bearer ` for a permanent 401, with nothing logged.
  def test_an_empty_ping_key_counts_as_missing
    Stablemate.config.ping_key = ""

    assert_nil wire
    assert_nil Stablemate.execution_subscriber
    assert_match(/no ping_key/, @logger.errors.first)
  end

  # The log line sits ABOVE the environment gate, which is the whole reason the
  # two are separate statements: a developer booting locally is told their
  # deploy has no key even though the allow-list was going to stop us wiring
  # anything up anyway.
  def test_the_missing_key_error_is_logged_even_when_the_environment_gate_is_shut
    Stablemate.config.ping_key = nil
    Stablemate.config.environment = "development"

    assert_nil wire
    assert_nil Stablemate.execution_subscriber
    assert_match(/no ping_key/, @logger.errors.first)
  end

  # The allow-list survives the rewrite. Without it a developer's laptop checks
  # in to production monitors and masks a real outage.
  def test_the_environment_allow_list_still_gates_wiring
    Stablemate.config.environment = "development"

    assert_nil wire
    assert_nil Stablemate.execution_subscriber

    perform("DailyDigestJob")
    assert_empty @client.pinged
    assert_empty @logger.errors
  end

  # §12 — a broken recurring.yml: one error line, app still boots. The rescue is
  # kept for exactly this: the registrar turns the parse failure into a
  # ConfigurationError (so `stablemate:sync` can name the file rather than blame
  # the network), that is a StandardError like the Psych::SyntaxError under it,
  # and dropping the rescue would turn "monitoring off" into "the app will not
  # boot" — strictly worse than the bug being fixed.
  def test_a_broken_recurring_yml_logs_one_error_and_still_boots
    Tempfile.create([ "broken", ".yml" ]) do |f|
      f.write("production: [unclosed\n")
      f.flush
      Stablemate.config.recurring_path = f.path

      assert_nil wire
      assert_nil Stablemate.execution_subscriber

      assert_equal 1, @logger.errors.size
      assert_match(/boot wiring skipped/, @logger.errors.first)
      assert_match(/not valid YAML/, @logger.errors.first)
      assert_match(/#{Regexp.escape(f.path)}/, @logger.errors.first)
    end
  end
end
