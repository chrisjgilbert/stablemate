class PingKey
  # Generate a fresh ping key for a project, persist only its SHA-256 digest +
  # last4, and return the raw token ONCE — it is never stored in plaintext, so
  # once this returns it cannot be recovered. Nothing needs to reconstruct it: the
  # install command prints the ready-to-paste curl lines from the host's own
  # config, so the web interface never re-displays a key after creation.
  class Issuance
    # sm_ping_<32 url-safe alphanumeric chars> (~190 bits of entropy). Same length
    # and alphabet as ApiKey — only the prefix differs (v1-scope §11).
    PREFIX = "sm_ping_"
    RANDOM_LENGTH = 32

    def initialize(project:, name:)
      @project = project
      @name = name
    end

    def issue
      raw_token = self.class.generate_raw_token
      ping_key = @project.ping_keys.create!(
        name: @name,
        token_digest: PingKey.digest(raw_token),
        token_last4: raw_token.last(4)
      )
      [ ping_key, raw_token ]
    end

    def self.generate_raw_token
      "#{PREFIX}#{SecureRandom.alphanumeric(RANDOM_LENGTH)}"
    end
  end
end
