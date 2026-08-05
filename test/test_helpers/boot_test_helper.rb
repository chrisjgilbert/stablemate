require "open3"

# Booting a THROWAWAY Rails process to test the things that only happen at boot.
#
# Some configuration exists only in an initializer, read once under a particular
# set of environment variables — Stripe keys, the Honeybadger key, STABLEMATE_HOST
# and SMTP_*. The already-booted test process can't re-run an initializer under a
# different env, which is what the process boundary is for.
#
# Each call pays for a FULL Rails boot, so keep the callers few: this is for
# decisions that genuinely cannot be reached any other way, not for anything
# merely convenient to assert at boot.
module BootTestHelper
  # `env` defaults to the test environment; pass RAILS_ENV yourself to override it
  # (ProductionEnvConfigTest boots production). A nil value UNSETS the variable in
  # the child, which is how "a self-hoster with no key configured" is expressed.
  def boot_app(script, env = {})
    out, err, status = Open3.capture3(
      { "RAILS_ENV" => "test" }.merge(env),
      "bin/rails", "runner", script, chdir: Rails.root.to_s
    )
    assert status.success?, "app failed to boot with env #{env.keys.inspect}: #{err}"

    # The script's JSON shares stdout with whatever the boot itself logged, and a
    # log line can land AFTER it as easily as before (production logs to STDOUT).
    # So take the last line that is actually the payload, not the last line — and
    # when there isn't one, say so with the output attached. A bare
    # JSON::ParserError on a tagged log line reads like the app failed to boot,
    # which is exactly the wrong place to start looking.
    payload = out.lines.reverse_each.find { |line| line.start_with?("{") }
    assert payload, <<~MESSAGE
      no JSON payload in the boot output for env #{env.keys.inspect}
      --- stdout ---
      #{out}
      --- stderr ---
      #{err}
    MESSAGE

    JSON.parse(payload)
  end
end
