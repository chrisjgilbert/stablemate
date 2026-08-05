# frozen_string_literal: true

module Stablemate
  module Registrars
    # A registrar produces registration tuples for POST /api/v1/monitors/sync. The
    # seam exists so further adapters (SidekiqCron, GoodJobCron, Whenever) are new
    # classes, not refactors.
    #
    # A tuple is a Hash:
    #   { registration_key:, name:, expected_interval_seconds:, grace_period_seconds: }
    class Registrar
      # @return [Array<Hash>] registration tuples.
      def tuples
        raise NotImplementedError, "#{self.class} must implement #tuples"
      end
    end
  end
end
