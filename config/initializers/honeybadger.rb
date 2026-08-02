# What an error report is allowed to carry off our infrastructure.
#
# Honeybadger is a third party, so this is a privacy decision, not a tuning knob
# — and its defaults are far narrower than ours: it filters `password`,
# `password_confirmation` and `HTTP_AUTHORIZATION`, and it does NOT inherit
# Rails' `config.filter_parameters`. Everything we already decided was too
# sensitive to write to our own logs was still being sent to someone else's.
#
# Two separate leaks, closed separately because Honeybadger reports params and
# the URL as different fields:
#
#   1. PARAMS — reuse Rails' list verbatim (`:token`, `:_key`, `:secret`,
#      `:crypt`, `:salt`, `:email`, …) so the two can never drift. Adding a key
#      in filter_parameter_logging.rb now protects both places at once.
#
#   2. THE URL — the ping token is a credential and travels in the path
#      (`/ping/:ping_token`), where no amount of param filtering reaches it. A
#      before_notify hook rewrites it out of the reported URL. Anyone holding a
#      raw ping token can forge check-ins for that monitor, so this is the same
#      class of secret as an API key, not merely an identifier.
#
# The privacy policy describes exactly this behaviour; if you change what is
# filtered, change that page too.
Honeybadger.configure do |config|
  config.before_notify do |notice|
    notice.url = notice.url.sub(%r{/ping/[^/?#]+}, "/ping/[FILTERED]") if notice.url
  end
end

Rails.application.config.after_initialize do
  Honeybadger.config[:"request.filter_keys"] =
    (Honeybadger.config[:"request.filter_keys"].to_a.map(&:to_s) +
      Rails.application.config.filter_parameters.map(&:to_s)).uniq
end
