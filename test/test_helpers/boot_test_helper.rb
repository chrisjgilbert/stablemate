require "open3"

# Booting a THROWAWAY Rails process to test the things that only happen at boot.
#
# Some of our configuration exists only in an initializer: pay.rb registers the
# Stripe processor and bridges its keys, honeybadger.rb assigns the API key,
# production.rb reads STABLEMATE_HOST/SMTP_*, and Pay decides whether to mount its
# own routes. None of that can be exercised from inside the already-booted test
# process — the suite would have to re-run an initializer under different
# environment variables, which is exactly what a process boundary is for. A broken
# initializer would otherwise crash the real instance on boot with every test green.
#
# So: boot with the env under test, print the resulting config as JSON, read it
# back. Each call pays for a full boot, so this belongs to the handful of decisions
# that genuinely only exist at boot — see BillingBootTest, HoneybadgerApiKeyTest,
# PayAutomountRoutesTest and ProductionEnvConfigTest, which are its only callers.
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
