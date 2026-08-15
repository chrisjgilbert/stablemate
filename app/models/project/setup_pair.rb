class Project
  # Issue the credential pair the setup command embeds — reached via
  # project.issue_setup_pair! (v1-scope §7).
  #
  # Both keys at once, because issuing only the API key seeds a project that can
  # register monitors and never check one in: the permanently-grey-row failure §7
  # exists to prevent. The raw values are returned and never stored, so the render
  # that follows this call IS §4's shown-once moment.
  class SetupPair
    Result = Struct.new(:api_key_token, :ping_key_token, :superseded, :kept, keyword_init: true) do
      # Used keys are left live, and the panel says so: at that point the user is
      # in §4's add-before-remove rotation, not a do-over.
      def kept_live? = kept.positive?
    end

    def initialize(project)
      @project = project
    end

    # Regenerating must not silently accumulate permanently-valid pairs. Every
    # click would otherwise mint another, and §9.4's mismatch guard — which warns
    # only when the configured key matches NO live key — would stay silent by
    # design while the project accumulated credentials nobody is tracking.
    #
    # The discriminator is `last_used_at`: still NULL means the key was never
    # verified and never synced, which is the onboarding do-over. A key that has
    # been used may be deployed somewhere, so revoking it here would be the one
    # thing this panel must never do — take a working install offline.
    def issue_setup_pair!
      @project.transaction do
        superseded, kept = revoke_superseded
        api_key_token = ApiKey.issue(project: @project, name: DEFAULT_NAME).last
        ping_key_token = PingKey.issue(project: @project, name: DEFAULT_NAME).last

        return Result.new(api_key_token:, ping_key_token:, superseded:, kept:)
      end
    end

    DEFAULT_NAME = "Setup".freeze

    private
      # Only the pairs THIS panel issued, which is what "the pair it supersedes"
      # means. Sweeping every unused key in the project would reach ones it never
      # minted: a second ping key generated from the Ping keys panel for §4's
      # add-before-remove rotation, or a pair pasted straight into .kamal/secrets
      # without running install locally, both still have a NULL last_used_at
      # because nothing has exercised them YET. Destroying those is the same harm
      # the never-used rule exists to avoid, arriving from the other direction —
      # last_used_at nil means "not used yet", never "safe to delete".
      def revoke_superseded
        unused, used = (@project.api_keys.to_a + @project.ping_keys.to_a)
                         .select { |key| key.name == DEFAULT_NAME }
                         .partition { |key| key.last_used_at.nil? }
        unused.each(&:destroy)
        [ unused.size, used.size ]
      end
  end
end
