# The two Honeybadger settings that are ours rather than the gem's, both of them
# here rather than in config/honeybadger.yml: WHERE THE API KEY COMES FROM (see
# the assignment inside `configure` below) and WHAT AN ERROR REPORT IS ALLOWED TO
# CARRY off our infrastructure (the rest of this note). Everything else — env,
# root, insights — stays in the YAML, which is where the gem's docs put it.
#
# Honeybadger is a third party, so filtering is a privacy decision, not a tuning
# knob — and its own defaults are far narrower than ours: it filters `password`,
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

# Initializers load alphabetically, so `stablemate.rb` hasn't run yet — load it
# now for honeybadger_api_key below. stablemate.rb self-guards the second load.
require_relative "stablemate"

# One rule, applied everywhere a path can surface, so the two can't drift.
ping_token_in_path = %r{/ping/[^/?#]+}
redacted_ping_path = "/ping/[FILTERED]"

Honeybadger.configure do |config|
  # The key is NOT in config/honeybadger.yml, because that file is git-tracked and
  # self-hosters clone it: a literal there ships our project's credential to
  # everyone and routes their exceptions into it. ENV first, then credentials —
  # the same rule as every other third-party secret. nil is a supported state: the
  # gem logs "API key is missing" and drops the notice, so a keyless instance
  # boots and runs normally with reporting off.
  #
  # ⚠️ OWNER ACTION: the key that used to live in the YAML is in this repository's
  # git history permanently and must be ROTATED in the Honeybadger dashboard. No
  # code change can undo that; deleting the line only stops it spreading further.
  #
  # Assigned only when we actually have one. A value set from a `configure` block
  # outranks every other source the gem reads (Config#get checks @ruby first), so
  # an unconditional assignment would push `nil` over a key a self-hoster set the
  # gem's own way — in their honeybadger.yml, or via HONEYBADGER_CONFIG_PATH —
  # and switch their reporting off with nothing to read that said why. Skipping
  # the assignment leaves those paths intact, and there is no key in the
  # repository for them to fall back TO.
  if (api_key = Stablemate.honeybadger_api_key)
    config.api_key = api_key
  end

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

# Deferred to after_initialize rather than run here, because it has to read the
# list filter_parameter_logging.rb builds: initializers run in filename order, so
# `f` before `h` is luck rather than a contract. (The before_notify hook above
# stays where it is — a notice can be raised during boot, so it registers as
# early as it can.)
Rails.application.config.after_initialize do
  # Rails replaces config.filter_parameters in place with a precompiled Regexp
  # the first time a request is served. We run before that, so we get keywords —
  # but pass a Regexp through as a Regexp rather than to_s'ing it, because
  # Honeybadger escapes strings: a stringified Regexp would be a filter that
  # matches nothing at all, and it would fail silently.
  filter_keys = Honeybadger.config[:"request.filter_keys"].to_a +
    Rails.application.config.filter_parameters + [ "HTTP_COOKIE" ]

  Honeybadger.config[:"request.filter_keys"] =
    filter_keys.map { |key| key.is_a?(Regexp) ? key : key.to_s }.uniq
end
