# frozen_string_literal: true

# Set is only autoloaded from Ruby 3.2 and the gemspec's floor is 3.1, so
# #reportable_class_to_keys's `to_set` would be a NoMethodError on a supported
# interpreter. That call sits under the boot rescue (§6.5), which would turn it
# into "boot wiring skipped" — the listener never attached and every check-in
# silently disabled, i.e. the incident this redesign exists to fix, reproduced on
# the gem's own oldest Ruby. The general rule: no stdlib that 3.2+ merely
# autoloads may be used unrequired.
require "set"

module Stablemate
  module Registrars
    # A registrar produces registration tuples for POST /api/v1/monitors/sync. The
    # seam exists so further adapters (SidekiqCron, GoodJobCron, Whenever) are new
    # classes, not refactors.
    #
    # A tuple is a Hash:
    #   { registration_key:, name:, expected_interval_seconds:, grace_period_seconds: }
    class Registrar
      # @return [Array<Hash>] registration tuples. The NARROWER set: tasks with no
      #   schedule, command-only tasks and unsizable schedules are all skipped.
      def tuples
        raise NotImplementedError, "#{self.class} must implement #tuples"
      end

      # @return [Hash{String=>Array<String>}] job class name -> task keys. The
      #   WIDER set, and the only direction that exists: a tuple carries no class
      #   name at all, so this cannot be recovered from #tuples.
      def class_to_keys
        raise NotImplementedError, "#{self.class} must implement #class_to_keys"
      end

      # @return [Array<Hash>] what this registrar declined to send, and why:
      #   `[{ registration_key:, reason: }]`. §6.1's report prints a skip beside
      #   the tasks that registered, because a skipped job is silently
      #   UNMONITORED and this line is the only place the run mentions it.
      #   Defaults to none: a registrar with nothing to skip has nothing to say.
      def skips
        []
      end

      # @return [Array<String>] every task key this registrar can SEE, BEFORE
      #   #tuples' skips.
      #
      #   Abstract rather than defaulted to the registerable keys, deliberately.
      #   This is the list a `PRUNE=1` run sends as `declared_keys`, and the
      #   server retires exactly the orphan candidates ABSENT from it (§6.1) — so
      #   an adapter answering "the keys I registered" would retire the monitor
      #   of a live job the moment a typo made its task unregisterable, turning a
      #   YAML mistake into monitoring-off. Answer what the config declares, not
      #   what this run managed to derive from it.
      def declared_keys
        raise NotImplementedError, "#{self.class} must implement #declared_keys"
      end

      # @return [Boolean] whether #declared_keys can be trusted as the COMPLETE
      #   set of what this registrar's source declares.
      #
      #   A `PRUNE=1` run sends that list and the server retires every orphan
      #   absent from it, so a registrar that read nothing — a missing file, a
      #   path that resolves elsewhere in the deploy container, a section that
      #   turned out not to be a task list — must say so and have the prune
      #   dropped. Handing the server a short list is how a broken parse retires
      #   the lot, which is §6.1's incident rather than a nuisance. The default
      #   is the weakest honest answer; a registrar that can tell "read nothing"
      #   from "declares nothing" should say so precisely.
      def declares_tasks?
        !declared_keys.empty?
      end

      # Which job classes may check in, and under which task keys (§6.3).
      #
      # The address cache used to answer this by accident — a class-name fallback
      # asked the server-supplied map "does a monitor exist with this name?" — so
      # deleting the cache deletes the allow-list with it. Intersecting the two
      # structures above restores it locally: a class reports only under keys this
      # registrar also registers, and a task the registrar skipped (an underivable
      # schedule) can no longer check in against a monitor that was never created.
      #
      # Deliberately computed from the registrar's own two structures and nothing
      # else, which is what keeps `c.monitors` out: those keys have no job class,
      # and one that happened to equal a host job class name would bind that class
      # to a shell script's monitor — a green monitor for a backup that has been
      # failing, precisely the failure this product exists to prevent. So the two
      # sets stay apart by construction: may-register is recurring.yml PLUS
      # `c.monitors` and belongs to the sync command, which is why this registrar
      # reads recurring.yml only; may-report-by-class is what this method answers,
      # and `c.monitors` must never reach it.
      def reportable_class_to_keys
        registerable = tuples.map { |tuple| tuple[:registration_key] }.to_set

        class_to_keys
          .transform_values { |keys| keys.select { |key| registerable.include?(key) } }
          .reject { |_class_name, keys| keys.empty? }
      end
    end
  end
end
