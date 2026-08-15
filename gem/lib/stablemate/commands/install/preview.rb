# frozen_string_literal: true

require_relative "../task_lines"

module Stablemate
  module Commands
    class Install
      # "This is what will be monitored" — §6.6's preview, and the reason install
      # is worth running before a deploy rather than after one.
      #
      # It reads the PRODUCTION section explicitly, and says so. That is the trap
      # the transcript hides: the registrar resolves recurring.yml's section from
      # the CURRENT environment and install runs on a dev machine, so an unpinned
      # preview shows the development resolution — zero tasks, for the standard
      # production-sectioned layout. What the user is asking is what *production*
      # will register.
      class Preview
        # The largest-gap rule surprises exactly when it matters, and this is the
        # one moment the user can still fix it — before the first deploy, rather
        # than on the Tuesday a 72-hour window fails to alert.
        DERIVATION_NOTE = "  (an interval is the LARGEST gap between runs, so a weekday-only cron derives 72h " \
                          "from the Friday→Monday hole — tighten one with c.overrides.)"

        # Said out loud, because everything above it looks exactly like a run that
        # DID something. Onboarding is the pressure that would erode §6.1's
        # environment guard ("just FORCE=1 the first time"); dry-run-by-design
        # removes the temptation, and only says so if it says so.
        DRY_RUN = "  (nothing is registered here — `bin/rails stablemate:sync` does that, in production, " \
                  "from your deploy hook.)"

        # result:           what a sync from here WOULD send (Registration#preview).
        # tasks_in_section: whether the file yielded any task at all under this
        #                   section, registerable or not — the two empty cases
        #                   below have different remedies, so they are different
        #                   messages.
        def initialize(result:, environment:, path:, file_present:, tasks_in_section:)
          @result = result
          @environment = environment
          @path = path
          @file_present = file_present
          @tasks_in_section = tasks_in_section
        end

        def lines
          [ source_line ] + declared_only_header + task_lines + notes
        end

        private
          attr_reader :result, :environment, :path, :file_present, :tasks_in_section

          def source_line
            return missing_file_line unless file_present
            return empty_section_line unless tasks_in_section

            "reading #{path} (#{environment} section) — this is what will be monitored:"
          end

          # A NOTE, not an error — the app may simply not have recurring jobs yet.
          # (Unlike sync, where registering nothing is a failure: §6.1.)
          def missing_file_line
            "reading #{path} — none found yet, so there are no recurring jobs to monitor. That is fine: " \
            "declare them there, or declare non-Rails work with c.monitors."
          end

          # Reported BY NAME, and deliberately a different sentence from the one
          # above: a file that exists but has nothing under this section is a
          # sectioning mistake, and "none found yet" would send the user looking
          # for a file that is right there.
          def empty_section_line
            "reading #{path} — no tasks under '#{environment}'. That is the section `stablemate:sync` " \
            "will register from, so check the file has a '#{environment}:' section (or no sections at all)."
          end

          # The odd case: nothing in the file, but c.monitors declares work that
          # WILL be registered. Without this line the entries below would sit
          # under a sentence saying there was nothing to show.
          def declared_only_header
            return [] if (file_present && tasks_in_section) || task_lines.empty?

            [ "c.monitors declares work of its own — this is what will be monitored:" ]
          end

          def task_lines
            @task_lines ||= TaskLines.new(entries: result.entries, registrar_skips: result.skips,
                                          mark: TaskLines::PLANNED).lines
          end

          def notes
            derivation = task_lines.empty? || !derived? ? [] : [ DERIVATION_NOTE ]
            derivation + [ DRY_RUN ]
          end

          def derived?
            result.entries.any? { |entry| entry[:schedule] }
          end
      end
    end
  end
end
