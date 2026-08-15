# frozen_string_literal: true

module Stablemate
  # Expects the including class to expose a (private) `config` reader.
  #
  # Swallows its own errors: the logger is pluggable public API, and these helpers
  # are called from last-line-of-defence rescues whose whole contract is that
  # nothing propagates into the host job — a raising #warn must not become the
  # thing that does.
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

      # For the states a deploy has to act on — a wrong ping key, an unregistered
      # task, a refusal that will not fix itself (§6.5), a boot with no key at
      # all. There is deliberately no Stablemate.log_error: Stablemate's singleton
      # does not include this module, so such a call would be a NoMethodError
      # swallowed by the boot rescue — which is why Boot is an object that
      # includes Logging rather than a block calling Stablemate.log_error.
      #
      # Falls back to #warn when the logger has no #error, because the gem's own
      # documented contract for c.logger is "responds to #warn / #info": a host
      # that supplied a minimal object honouring exactly that would otherwise
      # raise NoMethodError into the rescue below and lose EVERY error line
      # silently. Since boot makes no network call any more, those lines are the
      # only signal a misconfigured deploy produces — swallowing them leaves the
      # host with monitoring permanently disabled and nothing printed anywhere.
      def log_error(message)
        logger = config.logger || Stablemate.logger
        prefixed = "[stablemate] #{message}"

        logger.respond_to?(:error) ? logger.error(prefixed) : logger.warn(prefixed)
      rescue StandardError
        nil
      end
  end
end
