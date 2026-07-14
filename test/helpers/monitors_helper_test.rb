require "test_helper"

class MonitorsHelperTest < ActionView::TestCase
  test "humanize_duration rounds to the nearest unit" do
    assert_equal "45s", humanize_duration(45)
    assert_equal "1m", humanize_duration(59.6) # rounds up out of seconds
    assert_equal "45m", humanize_duration(45.minutes)
    assert_equal "1h", humanize_duration(59.6.minutes) # rounds up out of minutes
    assert_equal "22h", humanize_duration(22.hours)
    assert_equal "1d", humanize_duration(23.6.hours) # rounds up out of hours
    assert_equal "3d", humanize_duration(3.days)
  end

  # distance_of_time_in_words (what this replaced) always swaps its operands
  # so the distance is non-negative; humanize_duration must hold the same
  # guarantee for callers that don't independently ensure a future/past time.
  test "humanize_duration clamps a negative duration to 0s rather than going negative" do
    assert_equal "0s", humanize_duration(-1)
    assert_equal "0s", humanize_duration(-7_200)
  end

  test "humanize_duration_until counts down to a future time" do
    travel_to Time.zone.parse("2026-01-01 12:00:00 UTC") do
      assert_equal "22h", humanize_duration_until(22.hours.from_now)
    end
  end

  test "humanize_duration_since counts up from a past time" do
    travel_to Time.zone.parse("2026-01-01 12:00:00 UTC") do
      assert_equal "22h", humanize_duration_since(22.hours.ago)
    end
  end

  # The clock-skew case this fix targets: a timestamp that lands slightly in
  # the future relative to this process's clock must not render as negative.
  test "humanize_duration_since clamps a future time (clock skew) instead of going negative" do
    travel_to Time.zone.parse("2026-01-01 12:00:00 UTC") do
      assert_equal "0s", humanize_duration_since(5.minutes.from_now)
    end
  end
end
