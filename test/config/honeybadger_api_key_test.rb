require "test_helper"
require "open3"
require "tmpdir"

# The Honeybadger API key is a third-party credential and must not live in a
# git-tracked file: this repository is cloned by self-hosters, so a committed key
# hands them the owner's error-tracking project (their exceptions land in it) and
# hands anyone else the ability to flood it.
#
# It follows the same env-first/credentials-fallback rule as every other
# integration secret (CLAUDE.md, "Third-party integration secrets"), which for
# Honeybadger means an explicit `config.api_key` in the initializer rather than a
# literal in `config/honeybadger.yml`.
#
# Boot-time behaviour is the part a runtime stub cannot prove, so — like
# BillingBootTest — these boot a throwaway process and read the resulting config
# back out. A self-hoster with NO key must boot fine and simply not report.
class HoneybadgerApiKeyTest < ActiveSupport::TestCase
  def boot(env)
    script = <<~RUBY
      notify_error = begin
        Honeybadger.notify(RuntimeError.new("boot check"))
        nil
      rescue => e
        e.message
      end
      puts({ api_key: Honeybadger.config[:api_key], notify_error: notify_error }.to_json)
    RUBY
    out, err, status = Open3.capture3(
      { "RAILS_ENV" => "test" }.merge(env),
      "bin/rails", "runner", script, chdir: Rails.root.to_s
    )
    assert status.success?, "app failed to boot with env #{env.keys.inspect}: #{err}"
    JSON.parse(out.lines.last)
  end

  # Asked of the parsed document rather than the raw text, so the answer is the
  # one the gem itself would get — a commented-out example or a mention in prose
  # is fine, a setting is not.
  test "no Honeybadger API key is committed to the repository" do
    settings = YAML.safe_load(ERB.new(Rails.root.join("config/honeybadger.yml").read).result)

    refute settings.key?("api_key"),
      "config/honeybadger.yml is git-tracked and cloned by self-hosters — the key belongs in ENV/credentials"
  end

  test "the key from the environment is the one Honeybadger reports with" do
    assert_equal "hbp_boot_test_key", boot("HONEYBADGER_API_KEY" => "hbp_boot_test_key")["api_key"]
  end

  test "an instance with no key at all boots, and simply never reports" do
    cfg = boot("HONEYBADGER_API_KEY" => nil)

    assert_nil cfg["api_key"], "a keyless instance must not fall back to somebody else's project"
    assert_nil cfg["notify_error"], "a missing key must be a no-op, never an exception"
  end

  # Taking the key OUT of our YAML must not take everyone else's out too. A value
  # assigned in the initializer outranks every other source Honeybadger reads, so
  # assigning it unconditionally turned "we ship no key" into "no key can be
  # configured the gem's own way" — a self-hoster who put one in their
  # honeybadger.yml (the file the gem documents, and the one this repo tells them
  # is theirs to fill) got silence, with nothing to read that said why.
  test "a key set the gem's own way, in its YAML, still reaches Honeybadger" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "honeybadger.yml")
      File.write(path, "---\napi_key: 'hbp_self_hosters_own_key'\nenv: test\n")

      cfg = boot("HONEYBADGER_API_KEY" => nil, "HONEYBADGER_CONFIG_PATH" => path)

      assert_equal "hbp_self_hosters_own_key", cfg["api_key"],
        "the initializer must not shadow a key it hasn't got one to replace"
    end
  end

  # …and ours still wins when we have one, so the documented ENV/credentials route
  # is never quietly overridden by a stale file.
  test "the environment beats a key left in the YAML" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "honeybadger.yml")
      File.write(path, "---\napi_key: 'hbp_stale_yaml_key'\nenv: test\n")

      cfg = boot("HONEYBADGER_API_KEY" => "hbp_env_key", "HONEYBADGER_CONFIG_PATH" => path)

      assert_equal "hbp_env_key", cfg["api_key"]
    end
  end
end
