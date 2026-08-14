class PingKey
  # Resolve a presented raw bearer token back to its PingKey record by digest.
  #
  # Deliberately a near-copy of ApiKey::Authentication rather than a shared
  # lookup: the duplication is three lines, and it is what guarantees this lookup
  # can never see api_keys rows (v1-scope §4). Only `digest` and the coarsened
  # last_used_at write are shared, via HashedToken.
  module Authentication
    extend ActiveSupport::Concern

    included do
      include HashedToken
    end

    class_methods do
      # Opaque nil on any miss (no distinction between unknown/blank/revoked — the
      # caller maps every one of them to an identical 401).
      def authenticating(raw_token)
        return nil if raw_token.blank?

        presented = digest(raw_token)
        ping_key = find_by(token_digest: presented)
        return nil unless ping_key
        return nil unless ActiveSupport::SecurityUtils.secure_compare(ping_key.token_digest, presented)

        ping_key.record_use!
        ping_key
      end
    end
  end
end
