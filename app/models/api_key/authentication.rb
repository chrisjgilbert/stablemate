class ApiKey
  # Concern (architecture.md §4): resolve a presented raw bearer token back to its
  # ApiKey record by digest, in constant time, and record usage.
  #
  # We store a SHA-256 hex digest with a UNIQUE index, so the lookup is a single
  # indexed equality on the digest — the comparison happens inside Postgres on the
  # hashed value, never on the secret, and the digest is a preimage-resistant hash
  # of the token, so that is where the real protection lives. The extra
  # secure_compare is belt-and-braces only (both sides are the same already-found
  # digest); it never branches on whether a partial match existed.
  module Authentication
    extend ActiveSupport::Concern

    class_methods do
      # SHA-256 hex digest of a raw token. Stable, one-way, what we store + match on.
      def digest(raw_token)
        Digest::SHA256.hexdigest(raw_token.to_s)
      end

      # Look up the ApiKey for a presented raw token, or nil. Touches last_used_at
      # on a match so the UI can show recency. Constant-time digest compare; opaque
      # nil on any miss (no distinction between unknown/blank — the caller maps that
      # to an opaque 401).
      def authenticating(raw_token)
        return nil if raw_token.blank?

        presented = digest(raw_token)
        api_key = find_by(token_digest: presented)
        return nil unless api_key
        return nil unless ActiveSupport::SecurityUtils.secure_compare(api_key.token_digest, presented)

        api_key.touch(:last_used_at)
        api_key
      end
    end
  end
end
