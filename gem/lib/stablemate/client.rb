# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
# ERB::Util.url_encode addresses every check-in, and the gem supports a plain-Ruby
# host where nothing else loads ERB. Without this require the constant is missing —
# NameError, a StandardError, swallowed by #ping's own rescue and classified as
# transient, so every check-in would be dropped silently and the monitor would go
# down claiming it missed its check-in.
require "erb"
# Set is only autoloaded from Ruby 3.2; the gem's floor is 3.1.
require "set"

module Stablemate
  # HTTP client for the bearer-authed /api/v1 surface and the check-in hot path.
  # All calls use short timeouts; the check-in path swallows everything
  # (fire-and-forget) but still INSPECTS what came back — see #classify.
  class Client
    include Logging

    Error = Class.new(StandardError)

    # Defence in depth — the server truncates authoritatively to the same limit.
    # Deliberately duplicated from the server's Stablemate::ERROR_MESSAGE_LIMIT:
    # the gem is standalone, so it can't share the constant; keep the two in sync.
    ERROR_MESSAGE_LIMIT = 1_000

    # http_factory: an optional callable taking a URI and returning something
    # that responds to #post / #request. The default builds a Net::HTTP with the
    # configured timeouts. It exists so a caller can supply a different transport
    # — and so the suite can assert on the request that would go on the wire
    # without patching a private method onto the instance under test.
    def initialize(config = Stablemate.config, http_factory: nil)
      @config = config
      @http_factory = http_factory
      # The "log once" state of §6.5. One client serves the process (the subscriber
      # builds one and keeps it), so instance state IS per-process state — and it is
      # written from the subscriber's background dispatch threads, hence the lock.
      @logged_once = Set.new
      @logged_once_lock = Mutex.new
    end

    # Raises on a non-2xx / transport error so Registration#sync! can log and
    # continue.
    #
    # `prune` and `declared_keys` are omitted entirely on an ordinary run rather
    # than sent as false/[]: an empty key list beside a true flag is exactly the
    # pre-0.2.0-gem shape the server refuses to retire anything for (§6.1), so
    # keeping the pair absent keeps the two states distinguishable on the wire.
    def sync_monitors(app:, monitors:, declared_keys: nil, prune: false)
      body = { app:, monitors: }
      body.merge!(prune: true, declared_keys: Array(declared_keys)) if prune

      response = post_json(
        api_url("/api/v1/monitors/sync"),
        body,
        headers: bearer_headers
      )
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "sync failed: #{response.code}"
      end

      JSON.parse(response.body)
    end

    # §6.6's two verification calls, which prove both credentials end-to-end
    # before the user deploys anything. The key is an ARGUMENT rather than read
    # from the config: install verifies the keys it was handed on the command
    # line, which on a first run is the whole point — nothing has been written
    # yet for the config to have picked up.
    #
    # `GET /api/v1/verify` is §5.5's endpoint: it records nothing, which is what
    # makes it honest — a synthetic check-in would flip a monitor to `up` for a
    # job that has never run.
    def verify_ping_key(ping_key)
      verify(api_url("/api/v1/verify"), ping_key)
    end

    # The API key needs no endpoint of its own: listing monitors already proves
    # exactly the credential registration uses, and read-only.
    def verify_api_key(api_key)
      verify(api_url("/api/v1/monitors"), api_key)
    end

    # Takes the TASK KEY, not a URL: the address is built locally from a name the
    # gem already has, so there is nothing to fetch, cache or go stale.
    #
    # Never raises — the hot path must not break the host app — but it INSPECTS the
    # response rather than assuming success. See #classify for the four states.
    def ping(registration_key)
      classify(registration_key, post_check_in(registration_key, {}))
    rescue StandardError => e
      log_warn("check-in failed: #{e.class}: #{e.message}")
      :transient
    end

    # The SAME address as a success check-in, distinguished by the body. Same
    # fire-and-forget contract and same four states as #ping — never raises.
    def report_failure(registration_key, message:)
      classify(registration_key,
               post_check_in(registration_key,
                             status: 1, message: message.to_s[0, ERROR_MESSAGE_LIMIT]))
    rescue StandardError => e
      log_warn("failure report failed: #{e.class}: #{e.message}")
      :transient
    end

    # The ADDRESS a check-in is sent to, public because §6.6's ready-to-paste
    # `curl` block prints it: a hand-built URL there would be a second
    # interpretation of the address, free to drift from the one the gem actually
    # posts to — and the failure mode is a line the user pastes into cron that
    # 404s forever.
    #
    # ERB::Util.url_encode, not CGI.escape or URI.encode_www_form_component:
    # those two turn a space into "+", which decodes as a literal "+" in a PATH
    # segment, so a task named "my task" would 404 forever.
    def check_in_uri(registration_key)
      URI.join(config.endpoint, "/api/v1/monitors/#{ERB::Util.url_encode(registration_key)}/pings")
    end

    private
      attr_reader :config

      # Three outcomes, because two would lie. A server that never answered says
      # NOTHING about the key: reporting it as a bad credential sends the user to
      # regenerate a pair that was fine when the remedy is the endpoint or the
      # network. Only an explicit rejection is a rejection.
      #
      #   :ok          — 2xx, the credential works on that surface;
      #   :rejected    — 401/403: wrong, revoked, or the other kind of key;
      #   :unreachable — anything else (5xx, a redirect, a 404 from a server too
      #                  old to have the endpoint) and every transport failure.
      def verify(uri, key)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{key}"
        classify_verification(uri, http_for(uri).request(request))
      rescue StandardError => e
        log_warn("could not reach #{uri}: #{e.class}: #{e.message}")
        :unreachable
      end

      def classify_verification(uri, response)
        case response
        when Net::HTTPSuccess then :ok
        when Net::HTTPUnauthorized, Net::HTTPForbidden then :rejected
        else
          # Logged, not swallowed: the command can only say "the server did not
          # answer", and the code is the thing that tells a self-hoster whether
          # they are talking to the wrong host or an older Stablemate.
          log_warn("#{uri} answered #{response.code}, which says nothing about the credential.")
          :unreachable
        end
      end

      # The one request builder both arms share, so the success check-in and the
      # failure report cannot drift in headers, encoding or auth — and the
      # credential is read in exactly one place.
      def post_check_in(registration_key, params)
        uri = check_in_uri(registration_key)
        http_for(uri).post(uri.request_uri,
                           URI.encode_www_form(params),
                           "Content-Type" => "application/x-www-form-urlencoded",
                           "Authorization" => "Bearer #{config.ping_key}")
      end

      # §6.5's four failure states, plus :ok. They are kept apart because each has
      # its own remedy — and because NONE of them means the user's job failed,
      # which is what collapsing them into one bucket would report:
      #   :ok           — 2xx, the check-in landed;
      #   :unauthorized — 401, the ping key is wrong or revoked;
      #   :unregistered — 404, this task has no monitor (run stablemate:sync);
      #   :refused      — any other 4xx (and a redirect): the server is refusing for
      #                   a reason that will not resolve itself. Absorbing it is how
      #                   a server-side fault reaches the user as their job missing
      #                   a check-in;
      #   :transient    — 5xx, a timeout or a transport failure, absorbed by the
      #                   monitor's grace period.
      #
      # Takes the key as well as the response — §6.4's snippet passes only the
      # response, which cannot satisfy §6.5's "log once PER TASK NAME" for the 404
      # and other-4xx arms.
      def classify(registration_key, response)
        case response
        when Net::HTTPSuccess
          :ok
        when Net::HTTPUnauthorized
          # Once per process, not once per job run: one bad key must not print a
          # line for every job in the host app. The key itself is never logged.
          log_once([ :unauthorized ]) do
            "check-in rejected 401: the ping key is wrong or revoked — CHECK-INS ARE DISABLED " \
            "until it is replaced (see your project's setup panel)."
          end
          :unauthorized
        when Net::HTTPNotFound
          log_once([ :unregistered, registration_key ]) do
            "check-in rejected 404: no monitor is registered for '#{registration_key}' — " \
            "run `bin/rails stablemate:sync` to register it."
          end
          :unregistered
        when Net::HTTPClientError
          log_once([ :refused, registration_key ]) do
            "check-in for '#{registration_key}' refused #{response.code} — the server declined it, " \
            "so this run was NOT recorded. That is a refusal, not a missed run: a 429 means check-ins " \
            "are arriving faster than the rate limit, anything else wants looking at."
          end
          :refused
        when Net::HTTPRedirection
          # Not one of §6.5's four cases, and :transient would be a lie:
          # Net::HTTP does not follow redirects, so nothing was recorded — and an
          # endpoint that redirects redirects every request, forever (the usual
          # cause is an `http://` endpoint against an https-only server).
          log_once([ :refused, registration_key ]) do
            "check-in for '#{registration_key}' was redirected #{response.code} to " \
            "#{response['location'].inspect} and NOT recorded — check c.endpoint; redirects are " \
            "not followed."
          end
          :refused
        else
          :transient
        end
      end

      # Claims the slot BEFORE the logging IO. The natural check → log → record
      # shape races: the IO releases the GVL between the check and the record, and
      # two dispatch threads then both log.
      def log_once(scope)
        return unless @logged_once_lock.synchronize { @logged_once.add?(scope) }

        log_error(yield)
      end

      def api_url(path)
        URI.join(config.endpoint, path)
      end

      def bearer_headers
        { "Authorization" => "Bearer #{config.api_key}", "Content-Type" => "application/json" }
      end

      def post_json(uri, body, headers:)
        request = Net::HTTP::Post.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = JSON.generate(body)
        http_for(uri).request(request)
      end

      def http_for(uri)
        return @http_factory.call(uri) if @http_factory

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = config.timeout
        http.read_timeout = config.timeout
        http
      end
  end
end
