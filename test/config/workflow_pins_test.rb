require "test_helper"
require "yaml"

# Every third-party GitHub Action must be pinned to a commit SHA.
#
# The deploy job runs `webfactory/ssh-agent` with RAILS_MASTER_KEY, the Cloudflare
# origin TLS key, the database password and the registry password already in its
# environment, then hands it an authenticated SSH agent. A tag is a moving
# pointer: repoint `@v0.10.0` and that is remote code execution against production
# credentials, with nothing in this repository changing and no diff to review.
#
# This is a CHECK rather than a comment because the comment was not enough. The
# pins landed with a documented procedure that was itself wrong — it used
# `git ls-remote --tags --refs`, and `--refs` hides the `^{}` peel line that
# carries the commit for an ANNOTATED tag, so setup-chrome was pinned to a tag
# OBJECT. Nothing failed: CI stayed green, and the only symptom would have been
# dependabot quietly never opening another PR for it. Correctness was resting on
# whoever edited next reading a prose comment, which is the same shape the deploy
# preflight in this workflow had to stop relying on.
#
# Deliberately offline — no network, so it runs everywhere bin/ci does. It cannot
# tell you a SHA is the WRONG commit; it tells you a reference is not a pin at
# all, and that the version comment a human reads is present.
class WorkflowPinsTest < ActiveSupport::TestCase
  WORKFLOWS = Rails.root.glob(".github/workflows/*.yml").freeze
  # `owner/repo@<40 hex>` followed by a `# vX.Y.Z`-ish comment naming the version.
  PINNED = /\A[\w.-]+\/[\w.-]+@\h{40}\z/
  VERSION_COMMENT = /#\s*v?\d/

  test "there is at least one workflow to check" do
    assert_not_empty WORKFLOWS, "expected .github/workflows/*.yml"
  end

  test "every third-party action is pinned to a commit SHA with its version in a comment" do
    WORKFLOWS.each do |path|
      steps_in(path).each do |step|
        uses = step["uses"]
        # Local composite actions (./…) and Docker refs are not tag-pinnable.
        next if uses.nil? || uses.start_with?("./", "docker://")

        assert_match PINNED, uses,
          "#{path.basename}: `uses: #{uses}` is not pinned to a commit SHA. " \
          "Resolve the tag with `git ls-remote <url> 'refs/tags/<tag>*'` and take " \
          "the `^{}` line if there is one — an annotated tag's plain ref is the " \
          "tag object, not the commit."

        assert_match VERSION_COMMENT, raw_line_for(path, uses),
          "#{path.basename}: `#{uses}` has no trailing `# v…` comment, so nobody " \
          "reviewing this file can tell which version it is."
      end
    end
  end

  private
    def steps_in(path)
      YAML.safe_load(path.read, aliases: true).fetch("jobs", {}).values.flat_map { |job| job["steps"] || [] }
    end

    # The SHA is what YAML gives us; the version lives in a comment, which the
    # parser discards — so go back to the text for that half.
    def raw_line_for(path, uses)
      path.read.lines.find { |line| line.include?(uses) }.to_s
    end
end
