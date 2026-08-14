# frozen_string_literal: true

module Stablemate
  module Commands
    # One line per task, naming the interval AND where it came from — §6.1's
    # grammar, shared by the two commands that speak it: `stablemate:sync` prints
    # what it registered, `stablemate:install` (§6.6) previews what production
    # WILL register, and the two must read identically or the preview stops being
    # a preview.
    #
    # The derivation is half the line's job: the interval is the LARGEST gap
    # between runs, so a weekday-only `0 9 * * 1-5` derives 72 hours from the
    # Friday→Monday hole — correct by construction and useless to the user who
    # wants to know on Tuesday. Half the overrides people need become obvious the
    # moment they see that number and its source side by side, at the one moment
    # they can still fix it.
    #
    # The shape is binding; the glyphs are not.
    class TaskLines
      REGISTERED = "✓"
      SKIPPED = "✗"
      # Install's mark. A dry run has registered nothing, so nothing in it may
      # wear a tick — the indent lines the preview up with the report it is
      # previewing without claiming the outcome.
      PLANNED = " "

      # Wide enough to read as a column, capped so one pathological task key
      # cannot indent every other line off the screen.
      MIN_KEY_WIDTH = 12
      MAX_KEY_WIDTH = 40

      # entries:         this run's payload, carrying the provenance the lines
      #                  print (Registration::WIRE_KEYS is what the server sees).
      # registrar_skips: what the registrars declined to send, `[{
      #                  registration_key:, reason: }]`.
      # server_skips:    what the server refused, in the same shape. Empty for a
      #                  dry run, which sends nothing to be refused.
      # mark:            the glyph on a line that will register.
      def initialize(entries:, registrar_skips: [], server_skips: [], mark: REGISTERED)
        @entries = entries
        @registrar_skips = registrar_skips
        @server_skips = server_skips
        @mark = mark
      end

      def lines
        planned + unsent_refusals + skips
      end

      private
        attr_reader :entries, :registrar_skips, :server_skips, :mark

        # In payload order, because that is the order the user's own config reads
        # in. A key the server refused prints its refusal instead of a tick: the
        # count line is the authority on how many registered, and these lines are
        # the authority on which.
        def planned
          entries.map do |entry|
            reason = refusals[entry[:registration_key]]
            reason ? skip_line(entry[:registration_key], reason) : registered_line(entry)
          end
        end

        # A refusal naming something this run did not send — an unnamed entry, or
        # a server that answered about a key we never mentioned. Rare to the
        # point of being a bug somewhere, and still a job someone believes is
        # monitored, so it prints rather than vanishing.
        def unsent_refusals
          server_skips.reject { |skip| sent_keys.include?(skip[:registration_key]) }
                      .map { |skip| skip_line(skip[:registration_key], skip[:reason]) }
        end

        # A skip whose key registered anyway is not a skip the reader needs:
        # declaring a `command:`-only task in `c.monitors` is the remedy the
        # skip's own log line recommends, and printing both lines tells the user
        # their fix did not work.
        def skips
          registrar_skips.reject { |skip| sent_keys.include?(skip[:registration_key]) }
                         .map { |skip| skip_line(skip[:registration_key], skip[:reason]) }
        end

        def registered_line(entry)
          "#{mark} #{pad(entry[:registration_key])} every #{humanize(entry[:expected_interval_seconds])}" \
            "  (#{provenance(entry)})"
        end

        def skip_line(key, reason)
          "#{SKIPPED} #{pad(key)} skipped: #{reason}"
        end

        # Where the number came from. An override is named INLINE beside the
        # value it replaced rather than in a block of its own, so the line a user
        # scans for a task is the whole story for that task.
        def provenance(entry)
          derived = entry[:derived_interval_seconds]
          from = entry[:schedule] ? " from '#{entry[:schedule]}'" : ""

          if derived.nil?
            entry[:schedule] ? "derived#{from}" : "declared in c.monitors"
          elsif derived == entry[:expected_interval_seconds]
            # A grace-only override: the interval is still the derived one, and
            # saying "override" anyway is what stops a puzzled reader hunting for
            # a grace they can see in the config and not in the report.
            "override — derived#{from}"
          else
            "override — derived #{humanize(derived)}#{from}"
          end
        end

        def refusals
          @refusals ||= server_skips.to_h { |skip| [ skip[:registration_key], skip[:reason] ] }
        end

        # What this run actually put in the payload — the one list that decides
        # whether a key gets a line of its own or is folded into the entry it
        # already has.
        def sent_keys
          @sent_keys ||= entries.map { |entry| entry[:registration_key] }
        end

        def pad(key)
          key.to_s.ljust(width)
        end

        def width
          @width ||= keys.map(&:length).max.to_i.clamp(MIN_KEY_WIDTH, MAX_KEY_WIDTH)
        end

        def keys
          (sent_keys + server_skips.map { |skip| skip[:registration_key] } +
            registrar_skips.map { |skip| skip[:registration_key] }).map(&:to_s)
        end

        # The unit the schedule reads in, in whole units only: "every 26h" is the
        # number a user can compare against the cron line they wrote, and "every
        # 1.083d" is not.
        def humanize(seconds)
          seconds = seconds.to_i
          return "#{seconds / 3600}h" if seconds >= 3600 && (seconds % 3600).zero?
          return "#{seconds / 60}m" if seconds >= 60 && (seconds % 60).zero?

          "#{seconds}s"
        end
    end
  end
end
