# frozen_string_literal: true

module Stablemate
  module Commands
    class Install
      # Two real calls, made with the keys the command line handed us (§6.6): the
      # ping key against §5.5's `GET /api/v1/verify`, the API key against
      # `GET /api/v1/monitors`. Nothing about this is simulated, and nothing about
      # it records a check-in — a synthetic ping would flip a monitor to `up` for
      # a job that has never run (§11).
      #
      # Server responses stay opaque; this object knows which request it made, so
      # the CLI can name the key that failed. Naming neither would leave the user
      # re-pasting both.
      class Verification
        LABELS = { api: "API key", ping: "ping key" }.freeze

        def initialize(client:, api_key:, ping_key:, endpoint:)
          @client = client
          @api_key = api_key
          @ping_key = ping_key
          @endpoint = endpoint
        end

        # BOTH calls, always — a user who pasted one line wrong has usually
        # pasted both wrong, and stopping at the first costs them a whole extra
        # round trip to find out.
        def verify!
          @results = { api: client.verify_api_key(api_key), ping: client.verify_ping_key(ping_key) }
          self
        end

        def ok? = failures.empty?

        # The transcript's one-liner: `verifying credentials… ✓ API key valid   ✗ ping key REJECTED`.
        def line
          "verifying credentials… " + results.map { |kind, outcome| mark(kind, outcome) }.join("   ")
        end

        # One sentence per failed key, each with the remedy its own outcome
        # implies. A rejection is a key problem; an unreachable server says
        # NOTHING about the key, and telling someone to regenerate a credential
        # that was fine is worse than saying nothing.
        def failure_messages
          failures.map { |kind, outcome| message(kind, outcome) }
        end

        private
          attr_reader :client, :api_key, :ping_key, :endpoint, :results

          def failures
            results.reject { |_kind, outcome| outcome == :ok }
          end

          def mark(kind, outcome)
            case outcome
            when :ok then "✓ #{LABELS[kind]} valid"
            when :rejected then "✗ #{LABELS[kind]} REJECTED"
            else "✗ #{LABELS[kind]} unverified"
            end
          end

          def message(kind, outcome)
            return unreachable_message(kind) unless outcome == :rejected

            "the #{LABELS[kind]} was REJECTED by #{endpoint}. Nothing is monitored until it is right: " \
            "copy the whole `bin/rails stablemate:install …` line again from your project's setup panel " \
            "(both keys are shown once, so a truncated paste is the usual cause), and check the two keys " \
            "belong to the SAME project."
          end

          def unreachable_message(kind)
            "the #{LABELS[kind]} could not be checked: #{endpoint} did not answer (the reason is on the " \
            "gem's log). That says nothing about the key itself — check c.endpoint and the network, then " \
            "re-run. Nothing was written that depends on it."
          end
      end
    end
  end
end
