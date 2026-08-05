module MonitorsHelper
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

  def ping_url_for(monitor)
    ping_url(monitor.ping_token)
  end

  def curl_snippet_for(monitor)
    "curl -fsS #{ping_url_for(monitor)}"
  end

  # "Custom" is handled client-side by the preset_field Stimulus controller.
  def interval_presets
    [ [ "Every 5 minutes", 300 ], [ "Hourly", 3_600 ], [ "Daily", 86_400 ], [ "Weekly", 604_800 ] ]
  end

  def grace_presets
    [ [ "1 minute", 60 ], [ "5 minutes", 300 ], [ "15 minutes", 900 ], [ "1 hour", 3_600 ] ]
  end

  # Map the uptime concern's status symbols onto the UptimeBar partial's fill keys.
  def uptime_bar_days(series)
    series.map { |status| status == :no_data ? "no-data" : status.to_s }
  end

  def uptime_percent_label(percent)
    return "—" if percent.nil?

    "#{number_with_precision(percent, precision: 2)}%"
  end

  # Shared by the dashboard and the New-monitor action so the wording (and the
  # "Free plan" label, the seam for paid tiers) lives in one place.
  def monitor_limit_note(user)
    "You're at the #{user.monitor_limit}-monitor limit for the #{user.pro? ? "Pro" : "Free"} plan."
  end

  def mono_timestamp(time, seconds: false, blank: "never")
    return blank if time.blank?

    format = seconds ? "%Y-%m-%d %H:%M:%S UTC" : "%Y-%m-%d %H:%M UTC"
    time.utc.strftime(format)
  end

  # A deliberate hand-roll rather than Rails' distance_of_time_in_words: its fuzzy
  # buckets ("about 1 hour") are too coarse for the dashboard row's tight space,
  # which wants an exact "22h"/"45m". Clamped to a floor of 0 because last_ping_at
  # can land fractionally in the future relative to this process's clock under
  # multi-host clock skew.
  def humanize_duration(seconds)
    secs = [ seconds.round, 0 ].max
    return "#{secs}s" if secs < 60

    mins = (secs / 60.0).round
    return "#{mins}m" if mins < 60

    hours = (secs / 3_600.0).round
    return "#{hours}h" if hours < 24

    "#{(secs / 86_400.0).round}d"
  end

  def humanize_duration_until(time)
    humanize_duration(time - Time.current)
  end

  def humanize_duration_since(time)
    humanize_duration(Time.current - time)
  end
end
