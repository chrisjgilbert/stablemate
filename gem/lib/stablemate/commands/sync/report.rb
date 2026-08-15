# frozen_string_literal: true

require_relative "../task_lines"

module Stablemate
  module Commands
    class Sync
      # §6.1's output, which is product rather than plumbing: with the edit form
      # gone this run is the only place a user ever sees what their monitors were
      # configured with.
      #
      # The per-task half of it is TaskLines, shared with §6.6's install preview
      # so the two read identically — what is left here is everything only a real
      # run has: what the server refused, what it holds that this run does not
      # declare, what it retired, and the count.
      class Report
        ORPHANED = "!"
        RETIRED = "–"

        def initialize(result, environment:, recurring_path:)
          @result = result
          @environment = environment
          @recurring_path = recurring_path
        end

        # @return [Array<String>] the whole report, ending in §12's count.
        def lines
          body = task_lines + suppressed_prune_lines + orphan_lines + retirement_lines
          # The blank line sets the count apart from the list; with no list there
          # is nothing to set it apart from.
          body.empty? ? [ count_line ] : body + [ "", count_line ]
        end

        private
          attr_reader :result, :environment, :recurring_path

          def task_lines
            TaskLines.new(entries: result.entries, registrar_skips: result.skips,
                          server_skips: result.skipped).lines
          end

          # Reported by default and touched by nothing (§6.1): the task was
          # renamed or removed, and a monitor that was live keeps monitoring
          # until someone says otherwise — its pings stopping and it going down
          # is *correct*, because the job stopped existing.
          #
          # Split by which remedy applies, because one sentence for the whole
          # list has to be wrong about half of it: a monitor whose task is still
          # declared but unregisterable is one `PRUNE=1` deliberately SPARES, so
          # recommending the flag sends the operator to run it, watch nothing
          # happen, and only then be told why.
          def orphan_lines
            spared, absent = result.orphaned.partition { |key| skipped_keys.include?(key) }

            orphan_group(spared, "only a task this run could not register",
                         "(kept, and never retired while its task is declared — fix the skip above, or " \
                         "delete the monitor in the dashboard)") +
              orphan_group(absent, "no task in this run", absent_remedy)
          end

          def orphan_group(keys, clause, remedy)
            return [] if keys.empty?

            verb = keys.size == 1 ? "monitor matches" : "monitors match"

            [ "#{ORPHANED} #{keys.size} #{verb} #{clause}: #{keys.join(', ')}", "  #{remedy}" ]
          end

          # On a prune run the server has already spared everything it reported,
          # so the flag is not the remedy. The copy states the RULE rather than
          # asserting why each one survived, since an old server that ignored the
          # flag lands here too.
          def absent_remedy
            if result.pruned?
              "(not retired — the server spared them: their key is still declared in your config, or " \
              "they are not monitors a sync may retire)"
            else
              "(kept, state untouched — retire them with PRUNE=1, or restore the task)"
            end
          end

          # `PRUNE=1` asked for and dropped (Registration#prunable?). The
          # operator asked for a retirement and did not get one, so it belongs
          # where they are looking rather than only in the log.
          def suppressed_prune_lines
            return [] unless result.prune_suppressed?

            [ "#{ORPHANED} PRUNE was NOT applied: no task was found in #{recurring_path} for environment " \
              "'#{environment}', so this run cannot tell a removed task from a file it failed to read.",
              "  (nothing was retired — check the path resolves, and that the file has a " \
              "'#{environment}' section or none at all)" ]
          end

          # Retiring is a successful outcome: reversible, with history intact.
          # One line each, naming the monitor and how to get it back — a count
          # alone leaves the operator grepping the dashboard for what changed.
          def retirement_lines
            result.retired.map do |key|
              "#{RETIRED} retired #{key}: no task declares it any more. State and history are kept — " \
              "restore the task and the next sync revives it."
            end
          end

          def count_line
            "synced #{result.count} for environment '#{environment}'."
          end

          # The registrar's skips are the orphans the CLI can positively identify
          # as still-declared: they were seen in the file and not sent. (A
          # schedule-less entry is declared too and never reaches this list —
          # which is why the server, not this report, is the authority on what
          # may be retired.)
          def skipped_keys
            @skipped_keys ||= result.skips.map { |skip| skip[:registration_key] }
          end
      end
    end
  end
end
