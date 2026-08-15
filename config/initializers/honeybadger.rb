# The two Honeybadger settings that are ours rather than the gem's: where the API
# key comes from, and what an error report may carry off our infrastructure.
#
# Honeybadger is a third party, so filtering is a privacy decision. Its defaults
# cover only `password`, `password_confirmation` and `HTTP_AUTHORIZATION`, and it
# picks up Rails' filter_parameters only for notices raised inside a request — not
# in a job. Four fields leak separately, so each is closed separately:
#
#   1. PARAMS — reuse Rails' list verbatim so the two can't drift.
#   2. HTTP_COOKIE — reported raw, and carries the signed session_id cookie.
#      Honeybadger's per-cookie filter matches NAMES, and neither of ours looks
#      like a secret to a keyword match, so the whole header goes.
#   3. THE URL and THE BREADCRUMB TRAIL — no param filtering reaches either, and
#      the trail arrives again via Rails' process_action payload, which filters
#      the query string only. A before_notify hook rewrites both.
#
# What (3) defends changed in v1-scope §3.2. It used to be the ping token, which
# sat in the path as `/ping/:ping_token`; that endpoint is deleted, and a check-in
# is now `/api/v1/monitors/:registration_key/pings` — a task name, not a secret —
# with the credential in the Authorization header, which Honeybadger's own
# defaults filter. The hook is kept rather than deleted with the path it was
# written for, and retargeted at the credential SHAPE: that covers any channel a
# key could reach a notice through (an exception message, a breadcrumb, a URL),
# not just the one route that no longer exists.
#
# The privacy policy describes this behaviour; change it there too.

# Initializers load alphabetically, so `stablemate.rb` hasn't run yet — load it
# now for honeybadger_api_key below. stablemate.rb self-guards the second load.
require_relative "stablemate"

# One rule for both surfaces below, defined on Stablemate so it is testable and
# so the two can't drift.

Honeybadger.configure do |config|
  # Not in config/honeybadger.yml: that file is git-tracked and self-hosters clone
  # it, so a literal there would ship our credential to everyone.
  #
  # ⚠️ OWNER ACTION: the key that used to live in the YAML is permanently in this
  # repository's git history and must be ROTATED in the Honeybadger dashboard.
  #
  # Assigned only when we have one: a value set from `configure` outranks every
  # other source the gem reads, so an unconditional assignment would push nil over
  # a key a self-hoster set the gem's own way and silently switch reporting off.
  if (api_key = Stablemate.honeybadger_api_key)
    config.api_key = api_key
  end

  config.before_notify do |notice|
    notice.url = Stablemate.redact_credentials(notice.url) if notice.url

    # Scrub every string in the trail rather than the `:path` key alone: the
    # metadata Rails hands over is instrumentation payloads we don't control, and
    # a substitution that matches nothing is free.
    notice.breadcrumbs&.each do |breadcrumb|
      breadcrumb.metadata = breadcrumb.metadata.transform_values do |value|
        Stablemate.redact_credentials(value)
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
