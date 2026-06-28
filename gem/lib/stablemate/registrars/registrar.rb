# frozen_string_literal: true

module Stablemate
  module Registrars
    # Command contract (architecture.md §9): a registrar produces registration
    # tuples for POST /api/v1/monitors/sync. V1 ships only SolidQueueRecurring;
    # the seam exists so V2 adapters (SidekiqCron, GoodJobCron, Whenever) are new
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
