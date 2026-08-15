require "test_helper"

# Honeybadger is a THIRD PARTY. Anything an error report carries leaves our
# infrastructure, so what it carries has to be a deliberate decision rather than
# the gem's defaults — which filter only `password`, `password_confirmation` and
# `HTTP_AUTHORIZATION`.
#
# Three things would otherwise escape, each through a different field:
#   * API keys and tokens submitted as params (Rails filters `:token`/`:_key`/
#     `:secret`; Honeybadger's own defaults do not).
#   * A check-in credential reaching a report through some field nobody
#     enumerated. This used to be a narrow, known leak — the ping token sat in
#     the path as `/ping/:ping_token`, and param filtering cannot reach a path —
#     and v1-scope §3.2 closed it at the source by moving the credential into
#     the Authorization header. The redaction is kept and retargeted at the
#     credential SHAPE rather than deleted with the route, because "the one
#     place a key can appear" is exactly the assumption that was wrong before.
#   * The signed `session_id` cookie, which resumes a signed-in session for
#     anyone holding it, and rides along in the raw `HTTP_COOKIE` header.
#
# The assertions below build the REAL notice payload rather than a double: every
# one of those leaks lived in a field a `notice.url` stub cannot see.
class HoneybadgerFilteringTest < ActiveSupport::TestCase
  # Rails REPLACES config.filter_parameters IN PLACE with a single precompiled
  # Regexp the first time the app serves a request (Rails::Application
  # #filter_parameters, via env_config). Read at test time, this list is
  # therefore whatever the suite happened to do first: keywords in isolation, one
  # opaque Regexp once any request or system test has run in the same process —
  # which is why the parity assertion below has to snapshot it here, at load,
  # before a single test has executed.
  RAILS_FILTER_PARAMETERS = Rails.application.config.filter_parameters.dup.freeze

  PING_KEY = "sm_ping_pingkeyaaaabbbbccccdddd1111"
  SESSION_COOKIE = "sessioncookieffff2222gggg3333hhhh"
  RAILS_SESSION_COOKIE = "railssessioniiii4444jjjj5555kkkk"
  API_KEY = "sm_live_apikeyllll6666mmmm7777nnnn"
  REGISTRATION_KEY = "nightly_billing"

  test "Honeybadger filters everything Rails filters" do
    filtered = Honeybadger.config[:"request.filter_keys"].map(&:to_s)

    RAILS_FILTER_PARAMETERS.each do |key|
      assert_includes filtered, key.to_s,
        "#{key} is filtered from our logs but would still be sent to Honeybadger"
    end
  end

  # The corollary of the snapshot above: we inherit Rails' list at boot, so it
  # must still be keywords by then. A precompiled Regexp coerced to a String is
  # the silent failure — Honeybadger escapes it and the filter matches nothing,
  # so every key we thought we were inheriting would quietly stop being filtered.
  test "the inherited list is keywords, not a stringified Regexp" do
    assert_empty Honeybadger.config[:"request.filter_keys"].grep(/\A\(\?/),
      "a Rails filter that reaches us precompiled must stay a Regexp, not become inert text"
  end

  test "Honeybadger filters the cookie header, which no param list covers" do
    filtered = Honeybadger.config[:"request.filter_keys"].map(&:to_s)

    assert_includes filtered, "HTTP_COOKIE",
      "our session cookie is a credential; the raw Cookie header must not be reported"
  end

  test "no credential from a failed check-in request survives into the report" do
    payload = report_for_failed_check_in

    assert_no_match(/#{PING_KEY}/, payload,
      "the ping key is a credential and must never reach a third party")
    assert_no_match(/#{SESSION_COOKIE}/, payload,
      "the signed session_id cookie resumes a session — it must never leave")
    assert_no_match(/#{RAILS_SESSION_COOKIE}/, payload)
    assert_no_match(/#{API_KEY}/, payload)
  end

  # The point of redacting a shape rather than a route: a key that reaches a
  # report through a channel nobody enumerated is scrubbed anyway. Asserted from
  # both directions — the URL and the breadcrumb trail — because they are
  # populated by different code and the old rule only ever covered one of them by
  # accident of where the credential happened to sit.
  test "a credential leaked into a URL or a breadcrumb is redacted wherever it lands" do
    report = JSON.parse(report_for_failed_check_in)

    assert_no_match(/#{PING_KEY}/, report.dig("request", "url").to_s)
    assert_no_match(/#{PING_KEY}/, report.dig("breadcrumbs", "trail", 0, "metadata").to_s)
  end

  # The two channels no filter list reaches. Asserted separately from the
  # payload-wide sweep above so a regression names which one broke.
  test "a credential in the exception message is redacted" do
    report = JSON.parse(report_for_failed_check_in)

    message = report.dig("error", "message").to_s
    assert_no_match(/#{PING_KEY}/, message)
    assert_includes message, "check-in failed using [FILTERED]"
  end

  test "a credential in an unfiltered param name is redacted, at any depth" do
    report = JSON.parse(report_for_failed_check_in)

    params = report.dig("request", "params")
    assert_equal "[FILTERED]", params["debug"]
    assert_equal [ "[FILTERED]" ], params.dig("retry", "with")
  end

  # Redaction that took the diagnostic value with it would be its own bug. The
  # registration key is the TASK NAME, not a secret — it is the single most
  # useful field in a check-in error report, and it has to survive.
  test "the redacted report still says enough to debug with" do
    report = JSON.parse(report_for_failed_check_in)

    assert_includes report.dig("request", "url").to_s, REGISTRATION_KEY
    assert_equal "/api/v1/monitors/#{REGISTRATION_KEY}/pings",
                 report.dig("breadcrumbs", "trail", 0, "metadata", "path")
    assert_equal "Api::V1::Monitors::PingsController",
                 report.dig("breadcrumbs", "trail", 0, "metadata", "controller")
  end

  test "redaction leaves an unrelated URL alone" do
    notice = notice_for("https://stablemate.dev/monitors/42")

    run_before_notify_hooks(notice)

    assert_equal "https://stablemate.dev/monitors/42", notice.url
  end

  test "a notice with no URL and no breadcrumbs does not blow up the reporter" do
    notice = Honeybadger::Notice.new(Honeybadger.config, exception: RuntimeError.new("boom"))
    notice.url = nil

    assert_nothing_raised { run_before_notify_hooks(notice) }
  end

  private
    def run_before_notify_hooks(notice)
      Honeybadger.config.before_notify_hooks.each { |hook| hook.call(notice) }
    end

    # A notice for the URL, with no request behind it — enough to pin the URL rule.
    def notice_for(url)
      Honeybadger::Notice.new(Honeybadger.config, exception: RuntimeError.new("boom"), url: url)
    end

    # The whole JSON body Honeybadger would POST for an exception raised while
    # serving a check-in, with every credential the request actually carries
    # present in the Rack env and in the breadcrumb Rails' instrumentation leaves.
    #
    # The query string deliberately carries the ping key even though nothing in
    # the app would ever put it there: that is the "some field nobody
    # enumerated" case, and it is what the shape-based rule exists to survive.
    def report_for_failed_check_in
      notice = Honeybadger::Notice.new(
        Honeybadger.config,
        # The message carries a credential too: an exception raised while using a
        # key routinely interpolates it, and NO filter list reaches a message.
        exception: RuntimeError.new("check-in failed using #{PING_KEY}"),
        rack_env: check_in_rack_env,
        breadcrumbs: action_controller_breadcrumbs
      )
      run_before_notify_hooks(notice)
      notice.as_json.to_json
    end

    def check_in_rack_env
      url = "https://stablemate.dev/api/v1/monitors/#{REGISTRATION_KEY}/pings?debug=#{PING_KEY}"
      Rack::MockRequest.env_for(url, method: "POST").merge(
        "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters,
        "action_dispatch.request.parameters" => {
          "registration_key" => REGISTRATION_KEY,
          "controller" => "api/v1/monitors/pings", "action" => "create",
          # Filtered BY NAME, and "debug" is not a filtered name — so the value
          # ships raw unless the shape rule catches it. Nested, because params
          # are a tree and a credential is no less exposed one level down.
          "debug" => PING_KEY,
          "retry" => { "with" => [ PING_KEY ] }
        },
        "HTTP_COOKIE" => "session_id=#{SESSION_COOKIE}; _stablemate_session=#{RAILS_SESSION_COOKIE}",
        "HTTP_AUTHORIZATION" => "Bearer #{API_KEY}"
      )
    end

    # What Honeybadger records from `start_processing.action_controller`: the
    # payload keys it selects include `:path`, which is `request.filtered_path` —
    # and that filters the query string only, so anything in a path segment is
    # still raw when it gets here.
    def action_controller_breadcrumbs
      Honeybadger::Breadcrumbs::Collector.new(Honeybadger.config).tap do |collector|
        collector.add!(
          Honeybadger::Breadcrumbs::Breadcrumb.new(
            category: "request",
            message: "Action Controller Start Process",
            metadata: { controller: "Api::V1::Monitors::PingsController", action: "create",
                        path: "/api/v1/monitors/#{REGISTRATION_KEY}/pings",
                        leaked: "retrying with #{PING_KEY}" }
          )
        )
      end
    end
end
