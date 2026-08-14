# frozen_string_literal: true

module Stablemate
  class Registration
    # The whole story of one sync run: what it planned to register, what the
    # registrars would not send, and what the server made of the rest.
    #
    # An object rather than the array `sync!` used to answer, because §6.1 needs
    # both halves and names two traps in getting there:
    #
    # - the old return value was the process-wide address CACHE and the command
    #   printed `cache.size` — never a per-run count. #count is this run's, and
    #   nothing here answers to `.size` (`0.size` is 8, which is why that call
    #   had to be removed rather than re-pointed);
    # - `{}` is truthy, so "the run completed and registered nothing" and "the
    #   run did not complete" have to be different objects or a nil-returning
    #   replacement flips one into the other. A Result always means the run
    #   completed; nil (from #sync!'s rescue) always means it did not.
    class Result
      UNNAMED = "(unnamed)"
      NO_REASON = "no reason given"

      # entries:  this run's payload, carrying the provenance §6.1's report
      #           prints (see Registration::WIRE_KEYS for what the server sees).
      # skips:    what the registrars declined to send, `[{ registration_key:,
      #           reason: }]` — on the register-nothing paths, the only
      #           explanation there is, since no request was made to produce a
      #           server-side one.
      # response: the parsed sync envelope, or nil when no request was made.
      # pruned:   whether this run actually asked the server to retire orphans.
      # prune_suppressed: whether `PRUNE=1` was asked for and DROPPED, because
      #           the declared-key list bounding it could not be trusted (see
      #           Registration#prunable?). The report says so on stdout: the
      #           operator asked for a retirement and did not get one.
      attr_reader :entries, :skips, :registered, :skipped, :orphaned, :retired, :ping_key_last4

      def initialize(entries: [], skips: [], response: nil, pruned: false, prune_suppressed: false)
        @pruned = pruned
        @prune_suppressed = prune_suppressed
        # Junk-tolerant throughout: a malformed envelope must not cost the caller
        # the entries that DID register, and must never reach the report as a
        # nil key or an exception.
        envelope = response.is_a?(Hash) ? response : {}
        @entries = entries
        @skips = skips
        @registered = Array(envelope["monitors"]).grep(Hash)
        @skipped = normalise(envelope["skipped"])
        @orphaned = Array(envelope["orphaned"]).grep(String)
        @retired = Array(envelope["retired"]).grep(String)
        @ping_key_last4 = key_set(envelope["ping_key_last4"])
      end

      # THIS RUN's count.
      def count
        registered.size
      end

      # The exit status, in one place. §6.1 makes registering nothing a failure
      # on every path, because under CLI-only registration "the command exited 0"
      # is the entire evidence a deploy has that anything is monitored.
      def registered?
        !registered.empty?
      end

      def pruned?
        @pruned
      end

      def prune_suppressed?
        @prune_suppressed
      end

      private
        # §9.4 — the last four characters of every LIVE ping key for the project
        # the API key names, which the command compares the configured ping key
        # against. Three states, and the difference between the first two is the
        # whole guard:
        #
        # - nil: the server did not answer the question (any pre-§9.4 server), so
        #   no comparison may be made — warning on that would print a mismatch on
        #   every deploy against an older Stablemate;
        # - []: the project has no live ping key AT ALL, which IS a mismatch;
        # - the set: rotation keeps two live at once, so matching ANY is a match.
        #
        # Only a real Array counts. `Array("ab12")` would turn a malformed
        # envelope into a plausible one-element set and INVENT a mismatch, which
        # sends someone rotating a credential that was fine.
        def key_set(value)
          value.grep(String) if value.is_a?(Array)
        end

        # Into the registrars' own skip shape, so the command can print a server
        # refusal and a registrar skip with one line of code.
        def normalise(skipped)
          Array(skipped).grep(Hash).map do |entry|
            { registration_key: (entry["registration_key"] || UNNAMED).to_s,
              reason: (entry["reason"] || NO_REASON).to_s }
          end
        end
    end
  end
end
