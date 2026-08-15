# The two Honeybadger settings that are ours rather than the gem's: where the API
# key comes from, and what an error report may carry off our infrastructure.
#
# Honeybadger is a third party, so filtering is a privacy decision. Its defaults
# cover only `password`, `password_confirmation` and `HTTP_AUTHORIZATION`, and it
# picks up Rails' filter_parameters only for notices raised inside a request — not
# in a job. Two mechanisms, because the leaks come in two kinds:
#
# BY NAME — the gem's own filter list, extended at the bottom of this file:
#   1. PARAMS — reuse Rails' list verbatim so the two can't drift.
#   2. HTTP_COOKIE — reported raw, and carries the signed session_id cookie.
#      Honeybadger's per-cookie filter matches NAMES, and neither of ours looks
#      like a secret to a keyword match, so the whole header goes.
#
# BY SHAPE — the before_notify hook, for everything a name-based list cannot
# reach: the URL, the breadcrumb trail, the exception message, and a param whose
# NAME is innocuous while its value is a key.
#
# The shape rule replaced a narrower one, and why is the whole point. It used to
# rewrite `/ping/:ping_token` out of the URL, because that endpoint carried its
# credential in the path. v1-scope §3.2 deletes that endpoint — but the lesson of
# it is that enumerating the places a key can appear is what failed, so the rule
# is retargeted rather than retired: it now matches the credential shape wherever
# it lands. Adding a channel to the hook is cheap; discovering one you missed is
# not.
#
# The privacy policy describes this behaviour; change it there too.

# Initializers load alphabetically, so `stablemate.rb` hasn't run yet — load it
# now for honeybadger_api_key below. stablemate.rb self-guards the second load.
require_relative "stablemate"

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

    # The exception MESSAGE, which no filtering reaches: Honeybadger's filter
    # keys act on params and headers, and a credential interpolated into a raised
    # message ("check-in failed for sm_ping_…") sails past all of them.
    notice.error_message = Stablemate.redact_credentials(notice.error_message) if notice.error_message

    # PARAMS, which are filtered only BY NAME. `?debug=sm_ping_…` is not a
    # filtered key, so the value ships raw — and the whole reason this rule
    # matches a shape rather than a location is that "the one place a key can
    # appear" was the assumption that produced the leak it replaces.
    notice.params = Stablemate.redact_deeply(notice.params) if notice.params.present?

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
