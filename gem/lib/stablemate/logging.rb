# frozen_string_literal: true

module Stablemate
  # Shared "[stablemate]"-prefixed warning helper. Expects the including class
  # to expose a (private) `config` reader; an injected config's logger wins,
  # falling back to the global Stablemate.logger.
  #
  # Swallows its own errors: the logger is pluggable public API, and these
  # helpers are called from last-line-of-defense rescues (Subscriber#deliver,
  # the dispatch guard) whose whole contract is that nothing propagates into
  # the host job — a raising #warn must not become the thing that does.
  module Logging
    private
      def log_warn(message)
        (config.logger || Stablemate.logger).warn("[stablemate] #{message}")
      rescue StandardError
        nil
      end

      def log_info(message)
        (config.logger || Stablemate.logger).info("[stablemate] #{message}")
      rescue StandardError
        nil
      end
  end
end
