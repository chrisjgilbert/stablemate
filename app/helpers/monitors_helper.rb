module MonitorsHelper
  # Human-friendly rendering of an interval/grace in seconds ("1h", "5m", "1d").
  def humanize_seconds(seconds)
    return "—" if seconds.blank?

    secs = seconds.to_i
    if secs % 86_400 == 0
      "#{secs / 86_400}d"
    elsif secs % 3_600 == 0
      "#{secs / 3_600}h"
    elsif secs % 60 == 0
      "#{secs / 60}m"
    else
      "#{secs}s"
    end
  end

  # The full ping URL for a monitor (mono, copyable everywhere).
  def ping_url_for(monitor)
    ping_url(monitor.ping_token)
  end

  # A curl one-liner for the post-create card / docs.
  def curl_snippet_for(monitor)
    "curl -fsS #{ping_url_for(monitor)}"
  end

  # Interval presets offered in the form (label => seconds). "Custom" is handled
  # client-side by the preset_field Stimulus controller.
  def interval_presets
    [ [ "Every 5 minutes", 300 ], [ "Hourly", 3_600 ], [ "Daily", 86_400 ], [ "Weekly", 604_800 ] ]
  end

  def grace_presets
    [ [ "1 minute", 60 ], [ "5 minutes", 300 ], [ "15 minutes", 900 ], [ "1 hour", 3_600 ] ]
  end

  # Map the uptime concern's status symbols (:up/:partial/:down/:no_data) onto the
  # UptimeBar partial's fill keys ("up"/"partial"/"down"/"no-data").
  def uptime_bar_days(series)
    series.map { |status| status == :no_data ? "no-data" : status.to_s }
  end

  # Render the overall uptime percent, or an em-dash when there's no measured data.
  def uptime_percent_label(percent)
    return "—" if percent.nil?

    "#{number_with_precision(percent, precision: 2)}%"
  end

  # The at-limit sentence, shared by the dashboard and the New-monitor action so
  # the wording (and the "Free plan" label, the seam for paid tiers) lives in one
  # place. (phase-4 §3.2 — matter-of-fact, no upgrade/pricing.)
  def monitor_limit_note(user)
    "You're at the #{user.monitor_limit}-monitor limit for the #{user.pro? ? "Pro" : "Free"} plan."
  end

  # Standard mono UTC timestamp used across the events list and settings.
  def mono_timestamp(time, seconds: false, blank: "never")
    return blank if time.blank?

    format = seconds ? "%Y-%m-%d %H:%M:%S UTC" : "%Y-%m-%d %H:%M UTC"
    time.utc.strftime(format)
  end
end
