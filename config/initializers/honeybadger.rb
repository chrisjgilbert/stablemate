# What an error report is allowed to carry off our infrastructure.
#
# Honeybadger is a third party, so this is a privacy decision, not a tuning knob
# — and its own defaults are far narrower than ours: it filters `password`,
# `password_confirmation` and `HTTP_AUTHORIZATION`, and nothing else. (It does
# pick up Rails' `config.filter_parameters` for notices raised inside a request,
# from the Rack env — but not for one raised in a job or a rake task, where the
# only list is the one below.) Everything we already decided was too sensitive to
# write to our own logs was still being sent to someone else's.
#
# FOUR leaks, closed separately because Honeybadger reports each in its own
# field, and a fix to one does not reach the others:
#
#   1. PARAMS — reuse Rails' list verbatim (`:token`, `:_key`, `:secret`,
#      `:crypt`, `:salt`, `:email`, …) so the two can never drift. Adding a key
#      in filter_parameter_logging.rb now protects both places at once.
#
#   2. THE COOKIE HEADER — `HTTP_COOKIE` is reported raw, and it carries the
#      signed `session_id` cookie: anyone holding that value resumes the
#      session. No param list covers it (it is a header, not a param), and the
#      per-cookie filter matches on cookie NAMES — neither `session_id` nor
#      `_stablemate_session` looks like a secret to a keyword match. Both of our
#      cookies are credentials, so the whole header goes.
#
#   3. THE URL — the ping token is a credential and travels in the path
#      (`/ping/:ping_token`), where no amount of param filtering reaches it. A
#      before_notify hook rewrites it out of the reported URL. Anyone holding a
#      raw ping token can forge check-ins for that monitor, so this is the same
#      class of secret as an API key, not merely an identifier.
#
#   4. THE BREADCRUMB TRAIL — the same path arrives a second time, because
#      Honeybadger records Rails' `start_processing`/`process_action` events and
#      keeps their `:path` payload. That is `request.filtered_path`, which
#      filters the QUERY STRING only, so a path-segment credential is still raw.
#      Redacting the `url` field alone left the token sitting in the trail.
#
# The privacy policy describes exactly this behaviour; if you change what is
# filtered, change that page too.

# One rule, applied everywhere a path can surface, so the two can't drift.
ping_token_in_path = %r{/ping/[^/?#]+}
redacted_ping_path = "/ping/[FILTERED]"

Honeybadger.configure do |config|
  config.before_notify do |notice|
    notice.url = notice.url.sub(ping_token_in_path, redacted_ping_path) if notice.url

    # Scrub every string in the trail rather than the `:path` key alone: the
    # metadata Rails hands over is instrumentation payloads we don't control, and
    # a substitution that matches nothing is free.
    notice.breadcrumbs&.each do |breadcrumb|
      breadcrumb.metadata = breadcrumb.metadata.transform_values do |value|
        value.is_a?(String) ? value.sub(ping_token_in_path, redacted_ping_path) : value
      end
    end
  end
end

Rails.application.config.after_initialize do
  Honeybadger.config[:"request.filter_keys"] =
    (Honeybadger.config[:"request.filter_keys"].to_a.map(&:to_s) +
      Rails.application.config.filter_parameters.map(&:to_s) +
      [ "HTTP_COOKIE" ]).uniq
end
