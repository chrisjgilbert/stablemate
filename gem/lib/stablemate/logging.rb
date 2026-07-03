# frozen_string_literal: true

module Stablemate
  # Shared "[stablemate]"-prefixed warning helper. Expects the including class
  # to expose a (private) `config` reader; an injected config's logger wins,
  # falling back to the global Stablemate.logger.
  module Logging
    private
      def log_warn(message)
        (config.logger || Stablemate.logger).warn("[stablemate] #{message}")
      end

      def log_info(message)
        (config.logger || Stablemate.logger).info("[stablemate] #{message}")
      end
  end
end
