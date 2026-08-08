# Shared by ApiKey and PingKey: the hashing, and the last_used_at write. NOT the
# lookup, deliberately (v1-scope §4).
#
# The two credentials live in two tables precisely so a ping key cannot
# authenticate the management API. If a shared module also owned `authenticating`,
# the natural thing to type while moving code out of ApiKey is
# `ApiKey.find_by(...)` — and then both models would authenticate against
# api_keys and the separation would collapse silently and permissively. Each model
# keeps its own three-line `authenticating`; only what cannot name a table is
# shared.
module HashedToken
  extend ActiveSupport::Concern

  # last_used_at is written at most once per window. Its only reader is a "Last
  # used" column, and on the check-in hot path an unconditional write would queue
  # a tenant's concurrent check-ins behind one row (§5.2).
  LAST_USED_COARSENING = 5.minutes

  class_methods do
    def digest(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
    end
  end

  def record_use!
    return if last_used_at.present? && last_used_at > LAST_USED_COARSENING.ago

    touch(:last_used_at)
  end
end
