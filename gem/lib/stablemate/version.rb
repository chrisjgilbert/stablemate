# frozen_string_literal: true

module Stablemate
  # 0.2.0 is the phase-2 cutover (v1-scope §6.6, §8.1): check-ins addressed by
  # task key and authenticated by the ping key, registration by
  # `stablemate:sync` alone, `stablemate:install`, and the `prune` /
  # `declared_keys` wire fields the server describes as "0.2.0 or newer".
  VERSION = "0.2.0"
end
