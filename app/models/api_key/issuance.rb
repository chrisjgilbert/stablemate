class ApiKey
  # Operation (architecture.md §4): generate a fresh API key for a user, persist
  # only its SHA-256 digest + last4, and return the raw token ONCE. The raw token
  # is never stored in plaintext — once this returns it cannot be recovered.
  #
  # Reached via ApiKey.issue(user:, name:) -> [api_key, raw_token].
  class Issuance
    # sm_live_<32 url-safe alphanumeric chars> (~190 bits of entropy).
    PREFIX = "sm_live_"
    RANDOM_LENGTH = 32

    def initialize(user:, name:)
      @user = user
      @name = name
    end

    def call
      raw_token = self.class.generate_raw_token
      api_key = @user.api_keys.create!(
        name: @name,
        token_digest: ApiKey.digest(raw_token),
        token_last4: raw_token.last(4)
      )
      [ api_key, raw_token ]
    end

    def self.generate_raw_token
      "#{PREFIX}#{SecureRandom.alphanumeric(RANDOM_LENGTH)}"
    end
  end
end
