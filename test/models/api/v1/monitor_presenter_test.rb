require "test_helper"

# [unit] Api::V1::MonitorPresenter — the JSON representation of a monitor on the
# /api/v1 surface. The published field set is a contract with the gem, so it is
# asserted exactly here rather than key-by-key across the request tests.
class Api::V1::MonitorPresenterTest < ActiveSupport::TestCase
  setup do
    @monitor = users(:alice).projects.sole.monitors.create!(
      name: "Nightly billing",
      registration_key: "nightly_billing",
      expected_interval_seconds: 86_400,
      grace_period_seconds: 900,
      status: "up",
      source: "gem",
      last_ping_at: Time.utc(2026, 1, 1, 9, 0, 0),
      next_due_at: Time.utc(2026, 1, 2, 9, 0, 0)
    )
  end

  test "summary publishes exactly the index fields" do
    assert_equal %i[id name status registration_key ping_url last_ping_at next_due_at].sort,
      present.summary.keys.sort
  end

  test "summary carries the monitor's values and the ping url it was given" do
    summary = present.summary

    assert_equal @monitor.id, summary[:id]
    assert_equal "Nightly billing", summary[:name]
    assert_equal "up", summary[:status]
    assert_equal "nightly_billing", summary[:registration_key]
    assert_equal "https://example.test/ping/tok", summary[:ping_url]
    assert_equal Time.utc(2026, 1, 1, 9, 0, 0), summary[:last_ping_at]
    assert_equal Time.utc(2026, 1, 2, 9, 0, 0), summary[:next_due_at]
  end

  test "detail publishes the summary fields plus the configuration and uptime" do
    assert_equal (%i[id name status registration_key ping_url last_ping_at next_due_at] +
      %i[source expected_interval_seconds grace_period_seconds uptime_percent]).sort,
      present.detail.keys.sort
  end

  test "detail carries the monitor's configuration" do
    detail = present.detail

    assert_equal "gem", detail[:source]
    assert_equal 86_400, detail[:expected_interval_seconds]
    assert_equal 900, detail[:grace_period_seconds]
  end

  test "detail reports uptime_percent as nil when nothing has been measured" do
    assert_nil present.detail[:uptime_percent]
  end

  private
    def present
      Api::V1::MonitorPresenter.new(@monitor, ping_url: "https://example.test/ping/tok")
    end
end
