require "test_helper"

# Honeybadger is a THIRD PARTY. Anything an error report carries leaves our
# infrastructure, so what it carries has to be a deliberate decision rather than
# the gem's defaults — which filter only `password`, `password_confirmation` and
# `HTTP_AUTHORIZATION`.
#
# Three things would otherwise escape, each through a different field:
#   * API keys and tokens submitted as params (Rails filters `:token`/`:_key`/
#     `:secret`; Honeybadger's own defaults do not).
#   * The ping token, which is a CREDENTIAL and travels in the URL *path*
#     (`/ping/:ping_token`). Param filtering can't help there — the path is
#     reported both as its own `url` field and inside the breadcrumb trail — so
#     it is redacted explicitly in both.
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

  PING_TOKEN = "pingtokenaaaabbbbccccddddeeee1111"
  SESSION_COOKIE = "sessioncookieffff2222gggg3333hhhh"
  RAILS_SESSION_COOKIE = "railssessioniiii4444jjjj5555kkkk"
  API_KEY = "sm_live_apikeyllll6666mmmm7777nnnn"

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

  test "no credential from a failed ping request survives into the report" do
    payload = report_for_failed_ping_request

    assert_no_match(/#{PING_TOKEN}/, payload,
      "the ping token is a credential and must never reach a third party")
    assert_no_match(/#{SESSION_COOKIE}/, payload,
      "the signed session_id cookie resumes a session — it must never leave")
    assert_no_match(/#{RAILS_SESSION_COOKIE}/, payload)
    assert_no_match(/#{API_KEY}/, payload)
  end

  test "the redacted report still says enough to debug with" do
    report = JSON.parse(report_for_failed_ping_request)

    assert_equal "https://stablemate.dev/ping/[FILTERED]?duration_ms=12", report.dig("request", "url")
    assert_equal "/ping/[FILTERED]", report.dig("breadcrumbs", "trail", 0, "metadata", "path")
    assert_equal "PingsController", report.dig("breadcrumbs", "trail", 0, "metadata", "controller")
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
    # serving a ping, with every credential the request actually carries present
    # in the Rack env and in the breadcrumb Rails' instrumentation would leave.
    def report_for_failed_ping_request
      notice = Honeybadger::Notice.new(
        Honeybadger.config,
        exception: RuntimeError.new("boom"),
        rack_env: ping_rack_env,
        breadcrumbs: action_controller_breadcrumbs
      )
      run_before_notify_hooks(notice)
      notice.as_json.to_json
    end

    def ping_rack_env
      Rack::MockRequest.env_for("https://stablemate.dev/ping/#{PING_TOKEN}?duration_ms=12", method: "POST").merge(
        "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters,
        "action_dispatch.request.parameters" => {
          "ping_token" => PING_TOKEN, "controller" => "pings", "action" => "create"
        },
        "HTTP_COOKIE" => "session_id=#{SESSION_COOKIE}; _stablemate_session=#{RAILS_SESSION_COOKIE}",
        "HTTP_AUTHORIZATION" => "Bearer #{API_KEY}"
      )
    end

    # What Honeybadger records from `start_processing.action_controller`: the
    # payload keys it selects include `:path`, which is `request.filtered_path` —
    # and that filters the query string only, so a path-segment credential is
    # still raw when it gets here.
    def action_controller_breadcrumbs
      Honeybadger::Breadcrumbs::Collector.new(Honeybadger.config).tap do |collector|
        collector.add!(
          Honeybadger::Breadcrumbs::Breadcrumb.new(
            category: "request",
            message: "Action Controller Start Process",
            metadata: { controller: "PingsController", action: "create", path: "/ping/#{PING_TOKEN}" }
          )
        )
      end
    end
end
