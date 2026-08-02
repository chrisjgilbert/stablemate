require "test_helper"

# Honeybadger is a THIRD PARTY. Anything an error report carries leaves our
# infrastructure, so what it carries has to be a deliberate decision rather than
# the gem's defaults — which filter only `password`, `password_confirmation` and
# `HTTP_AUTHORIZATION`, and do not inherit Rails' own `filter_parameters`.
#
# Two things would otherwise escape:
#   * API keys and tokens submitted as params (Rails filters `:token`/`:_key`/
#     `:secret`; Honeybadger did not).
#   * The ping token, which is a CREDENTIAL and travels in the URL path
#     (`/ping/:ping_token`). Param filtering can't help there — the URL is
#     reported as its own field — so it is redacted explicitly.
class HoneybadgerFilteringTest < ActiveSupport::TestCase
  test "Honeybadger filters everything Rails filters" do
    filtered = Honeybadger.config[:"request.filter_keys"].map(&:to_s)

    Rails.application.config.filter_parameters.each do |key|
      assert_includes filtered, key.to_s,
        "#{key} is filtered from our logs but would still be sent to Honeybadger"
    end
  end

  test "a ping token in the URL is redacted before the report leaves" do
    notice = Struct.new(:url).new("https://stablemate.dev/ping/abcd1234efgh5678ijkl9012mnop3456?duration_ms=12")

    Honeybadger.config.before_notify_hooks.each { |hook| hook.call(notice) }

    assert_no_match(/abcd1234efgh5678ijkl9012mnop3456/, notice.url,
      "the ping token is a credential and must never reach a third party")
    assert_match %r{/ping/\[FILTERED\]}, notice.url
    assert_match(/duration_ms=12/, notice.url, "the rest of the URL is still useful for debugging")
  end

  test "redaction leaves an unrelated URL alone" do
    notice = Struct.new(:url).new("https://stablemate.dev/monitors/42")

    Honeybadger.config.before_notify_hooks.each { |hook| hook.call(notice) }

    assert_equal "https://stablemate.dev/monitors/42", notice.url
  end

  test "a notice with no URL does not blow up the reporter" do
    notice = Struct.new(:url).new(nil)

    assert_nothing_raised do
      Honeybadger.config.before_notify_hooks.each { |hook| hook.call(notice) }
    end
  end
end
