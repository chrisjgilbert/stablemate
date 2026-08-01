# frozen_string_literal: true

require "yaml"
require "fugit"
require_relative "registrar"

module Stablemate
  module Registrars
    # V1 registrar (architecture.md §9): reads Solid Queue's config/recurring.yml
    # and turns each task into a registration tuple. Environment sections are
    # resolved with Solid Queue's exact rule — the current env's section when
    # present, the whole file otherwise (see #tasks).
    #
    # - registration_key = the task key (decision #6).
    # - name             = the task key (default).
    # - expected_interval_seconds = derived from `schedule:` via Fugit. For
    #   irregular crons (uneven gaps, e.g. "0 9,17 * * *") we use the LARGEST gap
    #   (decision #5) so a normal late-but-within-the-longer-window run isn't a
    #   false alarm.
    # - grace_period_seconds = max(interval * DEFAULT_GRACE_FRACTION, 5 minutes).
    class SolidQueueRecurring < Registrar
      include Logging

      DEFAULT_GRACE_FRACTION = 0.15
      MIN_GRACE_SECONDS = 5 * 60
      # The window we measure the largest gap over is a HORIZON, not a fixed
      # number of occurrences: a cron's longest hole is only visible if the
      # window is wide enough to contain it, and the widest hole a weekly
      # schedule can have is the weekend. Sampling a fixed 50 occurrences of
      # "*/15 9-17 * * 1-5" covers a day and a half, so it measured the
      # weeknight gap (54,900s) and never the real Fri 17:45 -> Mon 09:00 one
      # (227,700s) — the monitor then went `down` every Friday evening and
      # false-recovered on Monday. Eight days guarantees at least one full
      # weekend transition wherever in the week the app boots.
      MIN_HORIZON_SECONDS = 8 * 24 * 60 * 60
      # A floor on samples as well as on span: sparse crons (monthly, "Feb 29
      # only") clear the horizon in two occurrences, but their gaps are uneven
      # across months and leap years, so we keep taking occurrences to find the
      # longest month / the century leap skip rather than register whichever
      # month we happened to boot in.
      MIN_OCCURRENCE_SAMPLES = 50
      # And a ceiling, so deriving an interval always terminates in bounded time:
      # a per-second cron would need ~700k occurrences to span the horizon. Any
      # cron dense enough to hit this ceiling has gaps of a second or two, which
      # are regular by then — stopping short costs nothing.
      MAX_OCCURRENCE_SAMPLES = 10_000

      def initialize(recurring_path: nil, environment: nil, config: Stablemate.config)
        @recurring_path = recurring_path || config.recurring_path
        # Shared resolver (Configuration#environment) so the railtie gate and
        # this file scoping always answer "what environment?" identically.
        @environment = (environment || config.environment).to_s
        @config = config
      end

      def tuples
        tasks.filter_map do |key, task|
          # Non-Hash entries (scalar garbage, nil sections seen through the
          # whole-file fallback) and schedule-less ones (other envs' sections
          # posing as tasks) can't be sized; skip, never crash boot.
          next unless task.is_a?(Hash)

          schedule = task["schedule"]
          next if schedule.nil?

          if job_class(task).nil?
            # A command:-only task runs as SolidQueue::RecurringJob, so the
            # execution subscriber (which resolves pings by job class name) can
            # never ping it — registering it would create a monitor that is
            # permanently down. Skip it, and say so. INFO, not WARN: command
            # tasks are a routine Solid Queue pattern (its own housekeeping
            # tasks use one), so this is expected on most apps.
            log_info("task '#{key}' has no class: — command tasks can't be auto-pinged; skipping. " \
                     "Wrap the command in a job class, or create a monitor manually and ping it from the command.")
            next
          end

          interval = interval_seconds(schedule)
          if interval.nil?
            # Skip rather than register a monitor we can't size — but say so, so a
            # silently-unmonitored job is visible to the operator.
            log_warn("could not derive an interval for task '#{key}' (schedule: #{schedule.inspect}); skipping.")
            next
          end

          {
            registration_key: key.to_s,
            name: (task["name"] || key).to_s,
            expected_interval_seconds: interval,
            grace_period_seconds: grace_seconds(interval)
          }
        end
      end

      # Map { job_class_name => [task_key, ...] } from the recurring config, for
      # the execution subscriber to resolve a perform back to its task(s).
      # (decision #6; a class shared by two tasks maps to both.)
      def class_to_keys
        tasks.each_with_object({}) do |(key, task), map|
          next unless task.is_a?(Hash)

          class_name = job_class(task)
          next if class_name.nil?

          (map[class_name] ||= []) << key.to_s
        end
      end

      # The largest gap between consecutive runs of a Fugit-parseable schedule,
      # in seconds. Returns nil if the schedule can't be parsed.
      def interval_seconds(schedule)
        parsed = Fugit.parse(schedule.to_s)
        return nil if parsed.nil?

        case parsed
        when Fugit::Duration
          parsed.to_sec.to_i
        when Fugit::Cron
          largest_cron_gap(parsed)
        end
      end

      private
        attr_reader :config

        # The task's job class name, or nil when the task can't be tracked by the
        # execution subscriber (no class:, or a blank one from templating). The
        # single pingability rule shared by tuples and class_to_keys, so the two
        # can't disagree about which tasks are trackable.
        def job_class(task)
          name = task["class"].to_s.strip
          name.empty? ? nil : name
        end

        def grace_seconds(interval)
          [ (interval * DEFAULT_GRACE_FRACTION).round, MIN_GRACE_SECONDS ].max
        end

        # Walk consecutive occurrences from now and return the longest gap. For a
        # regular cron every gap is equal; for an irregular one (9am & 5pm) the
        # gaps alternate and we want the longest (the overnight 16h, not the 8h);
        # for a weekday-restricted one the longest is the weekend, which is only
        # in view once the occurrences span MIN_HORIZON_SECONDS — hence sampling
        # to a horizon rather than to a count. Returns nil when fewer than two
        # occurrences exist (an unsizable schedule the caller skips and logs).
        def largest_cron_gap(cron)
          first = previous = largest = nil
          t = Time.now
          samples = 0

          while samples < MAX_OCCURRENCE_SAMPLES
            occurrence = cron.next_time(t)
            break if occurrence.nil?

            t = occurrence.to_t
            samples += 1
            largest = [ largest.to_i, (t - previous).to_i ].max if previous
            first ||= t
            previous = t
            break if samples >= MIN_OCCURRENCE_SAMPLES && (t - first) >= MIN_HORIZON_SECONDS
          end

          largest
        end

        # Solid Queue's exact section rule (configuration.rb#config_from):
        # `config[env] ? config[env] : config` — the current environment's
        # section when one is present, the WHOLE file otherwise. Mirroring it
        # exactly means we register precisely the tasks Solid Queue will run:
        # a development-only task never becomes a production monitor (pending
        # forever, eating a cap slot, or false-alarming after a stray ping),
        # and a mixed file's top-level tasks aren't registered in an env whose
        # section supersedes them. Memoized: tuples and class_to_keys are both
        # called on every boot, and one parse also means they can't see two
        # different versions of the file.
        def tasks
          @tasks ||= begin
            raw = YAML.safe_load_file(@recurring_path, aliases: true) || {}
            resolve_section(raw)
          rescue Errno::ENOENT
            {}
          end
        end

        # Solid Queue's rule, hardened: a scalar where a Hash belongs (a whole-
        # file string, or `production: true`) yields {} instead of the
        # NoMethodError that would silently disable the gem via the railtie's
        # boot rescue. (Solid Queue itself crashes on these; spec 21b doesn't
        # let us.)
        def resolve_section(raw)
          return {} unless raw.is_a?(Hash)

          section = raw[@environment]
          if section
            section.is_a?(Hash) ? section : {}
          else
            raw
          end
        end
    end
  end
end
