require "test_helper"

# The scrubber the Honeybadger initializer applies to notice URLs and breadcrumb
# metadata before anything leaves for a third party.
#
# It used to redact `/ping/:ping_token` out of the path, because that endpoint
# carried its credential in the URL. v1-scope §3.2 deletes that endpoint, so the
# rule is retargeted at the credential SHAPE rather than deleted with the route —
# a key can reach a notice through an exception message or a breadcrumb, not only
# through a URL.
class StablemateRedactionTest < ActiveSupport::TestCase
  test "both live credential prefixes are redacted" do
    api_key = ApiKey.issue(project: projects(:alices_default), name: "CI").last
    ping_key = PingKey.issue(project: projects(:alices_default), name: "Prod").last

    assert_equal "[FILTERED]", Stablemate.redact_credentials(api_key)
    assert_equal "[FILTERED]", Stablemate.redact_credentials(ping_key)
  end

  # gsub, not sub: a breadcrumb can carry more than one, and redacting only the
  # first would leak the rest while looking as though it had worked.
  test "every occurrence in one string is redacted, not just the first" do
    line = "tried sm_ping_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa then sm_ping_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    redacted = Stablemate.redact_credentials(line)

    assert_equal "tried [FILTERED] then [FILTERED]", redacted
    assert_no_match(/sm_ping_[a-z]/, redacted)
  end

  test "a credential embedded in a URL or a sentence is still found" do
    url = "https://stablemate.dev/api/v1/verify?debug=sm_live_cccccccccccccccccccccccccccccccc"

    assert_equal "https://stablemate.dev/api/v1/verify?debug=[FILTERED]",
                 Stablemate.redact_credentials(url)
  end

  # The callers hand over values they don't control — breadcrumb metadata is
  # whatever Rails' instrumentation put there — so a non-string must pass through
  # rather than raise inside a before_notify hook, where an exception would lose
  # the error report entirely.
  test "non-strings pass through untouched" do
    assert_nil Stablemate.redact_credentials(nil)
    assert_equal 42, Stablemate.redact_credentials(42)
    assert_equal({ a: 1 }, Stablemate.redact_credentials({ a: 1 }))
  end

  test "ordinary text is left alone" do
    assert_equal "no credential here", Stablemate.redact_credentials("no credential here")
    # A registration key is NOT a secret and must survive: it is the task name,
    # and redacting it would gut the diagnostic value of the report.
    assert_equal "/api/v1/monitors/nightly_backup/pings",
                 Stablemate.redact_credentials("/api/v1/monitors/nightly_backup/pings")
  end
end
