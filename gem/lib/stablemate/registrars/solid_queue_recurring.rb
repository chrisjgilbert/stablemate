# frozen_string_literal: true

require "yaml"
require "fugit"
require_relative "registrar"
require_relative "../declaration"

module Stablemate
  module Registrars
    # Reads Solid Queue's config/recurring.yml and turns each task into a
    # registration tuple.
    #
    # For irregular crons (uneven gaps, e.g. "0 9,17 * * *") the interval is the
    # LARGEST gap, so a normal late-but-within-the-longer-window run isn't a false
    # alarm.
    class SolidQueueRecurring < Registrar
      include Logging

      # A HORIZON, not a fixed number of occurrences: a cron's longest hole is only
      # visible if the window is wide enough to contain it, and the widest hole a
      # weekly schedule can have is the weekend. Sampling a fixed 50 occurrences of
      # "*/15 9-17 * * 1-5" covers a day and a half, so it measured the weeknight
      # gap and never the real Fri 17:45 -> Mon 09:00 one. Eight days guarantees at
      # least one full weekend transition wherever in the week the app boots.
      MIN_HORIZON_SECONDS = 8 * 24 * 60 * 60
      # A floor on samples as well as on span: sparse crons clear the horizon in two
      # occurrences, but their gaps are uneven across months and leap years.
      MIN_OCCURRENCE_SAMPLES = 50
      # And a ceiling, so deriving an interval always terminates in bounded time: a
      # per-second cron would need ~700k occurrences to span the horizon.
      MAX_OCCURRENCE_SAMPLES = 10_000

      # The report has room for the reason and nothing else; the log lines beside
      # these keep the remedy (§6.1).
      COMMAND_TASK = "command task, no class: to observe"

      def initialize(recurring_path: nil, environment: nil, config: Stablemate.config)
        @recurring_path = recurring_path || config.recurring_path
        # Shared resolver so the railtie gate and this file scoping always answer
        # "what environment?" identically.
        @environment = (environment || config.environment).to_s
        @config = config
      end

      def tuples
        derive!
        @tuples
      end

      # The same walk's other half: what could not be turned into a tuple, and
      # why (§6.1). Data as well as a log line, because the command prints one
      # line per task and an unregisterable job is exactly the line an operator
      # has to see — nothing later in the run mentions it again.
      def skips
        derive!
        @skips
      end

      # Every task key in the section this run resolves, BEFORE the skips above.
      #
      # This is what a `PRUNE=1` run sends as `declared_keys`, and it is the only
      # thing standing between a YAML typo and monitoring-off: a task whose
      # `class:` line was deleted is skipped here, stops matching its monitor and
      # would read to the server as an orphan. Present in this list, it is
      # reported and never retired (§6.1).
      #
      # Scoped by Solid Queue's own section rule for the same reason everything
      # else here is: "every key in recurring.yml" read literally would also
      # protect a key that exists only under another environment's section, and
      # the two readings retire different monitors.
      def declared_keys
        tasks.keys.map(&:to_s)
      end

      # Solid Queue's own test for a task — an entry it would schedule has a
      # `schedule:` — applied to the section this run resolved. That is what
      # separates a real (if unregisterable) task list from the two shapes that
      # silently UNDER-declare, and a prune bounded by an under-declared list
      # retires everything the list omits:
      #
      # - the file is not there (`tasks` answers {} for ENOENT — a mis-set path
      #   in a deploy container looks exactly like a host with no recurring jobs);
      # - the current environment has no section, so #resolve_section falls back
      #   to the whole file and the "keys" are the ENVIRONMENT NAMES. That one is
      #   worse than empty: `["production", "development"]` is non-empty and
      #   plausible, so an emptiness check passes it straight through.
      def declares_tasks?
        tasks.any? { |_key, task| task.is_a?(Hash) && task.key?("schedule") }
      end

      # Map { job_class_name => [task_key, ...] } for the execution subscriber to
      # resolve a perform back to its task(s). A class shared by two tasks maps to both.
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

        # One walk producing both halves, memoized: #tuples and #skips are two
        # views of the same decision, so computing them apart would let them
        # disagree about a task — and re-walking would re-log every skip notice
        # each time either is read (boot reads tuples, the sync command reads
        # both).
        def derive!
          return if @derived

          @tuples = []
          @skips = []
          tasks.each { |key, task| derive(key.to_s, task) }
          @derived = true
        end

        def derive(key, task)
          # Non-Hash entries (scalar garbage, nil sections seen through the
          # whole-file fallback) and schedule-less ones (other envs' sections
          # posing as tasks) can't be sized; skip, never crash boot. Silently:
          # these are not tasks anyone declared, so reporting them as skipped
          # jobs would be noise in the one place §6.1 keeps signal.
          return unless task.is_a?(Hash)

          schedule = task["schedule"]
          return if schedule.nil?

          if job_class(task).nil?
            # A command:-only task runs as SolidQueue::RecurringJob, so the execution
            # subscriber (which resolves pings by job class name) can never ping it —
            # registering it would create a permanently-down monitor. INFO, not WARN:
            # command tasks are a routine Solid Queue pattern.
            log_info("task '#{key}' has no class: — command tasks can't be auto-pinged; skipping. " \
                     "Wrap the command in a job class, or create a monitor manually and ping it from the command.")
            @skips << { registration_key: key, reason: COMMAND_TASK }
            return
          end

          interval = interval_seconds(schedule)
          if interval.nil?
            # Skip rather than register a monitor we can't size — but say so, so a
            # silently-unmonitored job is visible to the operator.
            log_warn("could not derive an interval for task '#{key}' (schedule: #{schedule.inspect}); skipping.")
            @skips << { registration_key: key, reason: "schedule #{schedule.inspect} sizes to no interval" }
            return
          end

          @tuples << {
            registration_key: key,
            name: (task["name"] || key).to_s,
            expected_interval_seconds: interval,
            grace_period_seconds: Declaration.default_grace(interval),
            # The RAW string, verbatim (§6.3). We parse the cron with Fugit and
            # then throw the expressiveness away, sending only the derived
            # interval — which is why a weekday job is inexpressible (§3.1).
            # Carrying the string from day one costs nothing (V1 detection ignores
            # it) and makes cron-aware detection later a server-only upgrade: no
            # gem release, no wire cutover.
            schedule: schedule.to_s
          }
        end

        # The single pingability rule shared by tuples and class_to_keys, so the two
        # can't disagree about which tasks are trackable.
        def job_class(task)
          name = task["class"].to_s.strip
          name.empty? ? nil : name
        end

        # For an irregular cron (9am & 5pm) the gaps alternate and we want the
        # longest (the overnight 16h, not the 8h); for a weekday-restricted one the
        # longest is the weekend, which is only in view once the occurrences span
        # MIN_HORIZON_SECONDS. Returns nil when fewer than two occurrences exist.
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

        # Solid Queue's exact section rule: the current environment's section when
        # one is present, the WHOLE file otherwise. Mirroring it exactly means we
        # register precisely the tasks Solid Queue will run — a development-only task
        # never becomes a production monitor. Memoized so tuples and class_to_keys
        # can't see two different versions of the file.
        def tasks
          @tasks ||= begin
            raw = YAML.safe_load_file(@recurring_path, aliases: true) || {}
            resolve_section(raw)
          rescue Errno::ENOENT
            {}
          rescue Psych::SyntaxError => e
            # A CONFIG error, not a sync failure. Psych::SyntaxError is a
            # StandardError, so left alone it lands in Registration#sync!'s
            # catch-all and the command reports a run that "did not complete" and
            # tells the operator to re-run — which will never help. Boot's own
            # rescue still catches this (a broken file must not stop the host
            # booting); what changes is that the command names the file.
            raise ConfigurationError,
                  "#{@recurring_path} is not valid YAML (#{e.message}). Nothing can be registered until it " \
                  "parses — this will not fix itself on the next deploy."
          end
        end

        # Hardened: a scalar where a Hash belongs (a whole-file string, or
        # `production: true`) yields {} instead of the NoMethodError that would
        # silently disable the gem via the railtie's boot rescue.
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
