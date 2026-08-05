require "test_helper"

# The Honeybadger API key is a third-party credential and must not live in a
# git-tracked file: this repository is cloned by self-hosters, so a committed key
# hands them the owner's error-tracking project (their exceptions land in it) and
# hands anyone else the ability to flood it. It follows the env-first/credentials
# rule every integration secret does (CLAUDE.md, "Third-party integration
# secrets"), which for Honeybadger means an explicit config.api_key in the
# initializer rather than a literal in config/honeybadger.yml.
class HoneybadgerSecretTest < ActiveSupport::TestCase
  # Asked of the parsed document rather than the raw text, so the answer is the
  # one the gem itself would get — a commented-out example or a mention in prose
  # is fine, a setting is not.
  test "no Honeybadger API key is committed to the repository" do
    settings = YAML.safe_load(ERB.new(Rails.root.join("config/honeybadger.yml").read).result)

    assert_not settings.key?("api_key"),
      "config/honeybadger.yml is git-tracked and cloned by self-hosters — the key belongs in ENV/credentials"
  end
end
