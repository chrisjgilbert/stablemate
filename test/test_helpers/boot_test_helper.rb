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

    # The last line only — anything the boot itself logged to stdout comes first.
    JSON.parse(out.lines.last)
  end
end
