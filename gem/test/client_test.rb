# frozen_string_literal: true

require_relative "test_helper"
require "net/http"

# §6.4/§6.5 — a check-in is addressed by TASK KEY (nothing is fetched), authed by
# the ping key in an Authorization header, and its response is classified into
# four states: ok, a wrong/revoked key, an unregistered task, a refusal that will
# not fix itself, and — everything else — transient.
class ClientTest < StablemateTest
  def setup
    super
    @logger = Stablemate::RecordingLogger.new
    Stablemate.configure do |c|
      c.endpoint = "https://sm.test"
      c.ping_key = "sm_ping_livekey"
      c.api_key = "sm_live_apikey"
      c.logger = @logger
    end
  end

  # Inject a recording transport through the client's own http_factory seam, so
  # the test asserts on the request that would go on the wire without patching a
  # private method onto the instance under test — and no real network.
  def client_capturing_request(response)
    captured = {}
    factory = ->(_uri) { RecordingHttp.new(response, captured) }
    [ Stablemate::Client.new(Stablemate.config, http_factory: factory), captured ]
  end

  # Stands in for the Net::HTTP the client would otherwise build.
  class RecordingHttp
    def initialize(response, captured)
      @response = response
      @captured = captured
    end

    def post(path, body, headers = nil)
      @captured.merge!(path: path, body: body, headers: headers)
      @response
    end
  end

  def ok = Net::HTTPOK.new("1.1", "200", "OK")
  def unauthorized = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
  def not_found = Net::HTTPNotFound.new("1.1", "404", "Not Found")
  def too_many = Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests")
  def server_error = Net::HTTPInternalServerError.new("1.1", "500", "Error")
  def redirect = Net::HTTPMovedPermanently.new("1.1", "301", "Moved Permanently")

  # --- Classification (§6.5), asserted through #ping — the public entry point it
  # exists to serve. Calling the private #classify would prove the case statement
  # works but not that #ping consults it. ---

  def ping_status(response, key: "daily_digest")
    client, captured = client_capturing_request(response)
    status = client.ping(key)
    # #ping swallows everything, so a state expectation alone would also be
    # satisfied by a client that blew up before it classified anything. Pin that
    # the request actually reached the transport, at phase 1's own route.
    assert_equal "/api/v1/monitors/#{key}/pings", captured[:path]
    status
  end

  def test_2xx_is_ok
    assert_equal :ok, ping_status(ok)
  end

  def test_401_is_an_unauthorized_key
    assert_equal :unauthorized, ping_status(unauthorized)
  end

  def test_404_is_an_unregistered_task
    assert_equal :unregistered, ping_status(not_found)
  end

  # Was a silent transient :error. §6.5 makes it its own state: absorbing a
  # refusal that will not resolve itself is how a server-side fault reaches the
  # user as their job missing a check-in.
  def test_any_other_4xx_is_a_refusal
    assert_equal :refused, ping_status(too_many)
  end

  def test_5xx_is_transient
    assert_equal :transient, ping_status(server_error)
  end

  # Not one of §6.5's four cases, and silently transient is the wrong answer:
  # Net::HTTP does not follow redirects, so the check-in was never recorded — and
  # an endpoint that redirects (`http://` against an https-only server) redirects
  # every request, forever. That is the silent-permanent-failure shape this whole
  # change exists to delete, so it gets a refusal's treatment.
  def test_a_redirect_is_a_refusal_not_a_transient
    assert_equal :refused, ping_status(redirect)
  end

  def test_a_redirect_is_logged_once_per_task_name
    client, = client_capturing_request(redirect)

    2.times { client.ping("daily_digest") }

    assert_equal 1, @logger.errors.size
    assert_match(/daily_digest/, @logger.errors.first)
    assert_match(/301/, @logger.errors.first)
  end

  # --- The wire shape (§6.4, §5.1) ---

  def test_a_check_in_posts_to_the_task_keys_route_with_the_ping_key
    client, captured = client_capturing_request(ok)

    assert_equal :ok, client.ping("daily_digest")

    assert_equal "/api/v1/monitors/daily_digest/pings", captured[:path]
    assert_equal "Bearer sm_ping_livekey", captured[:headers]["Authorization"]
    assert_equal "application/x-www-form-urlencoded", captured[:headers]["Content-Type"]
    # A success ping carries no params, but the form encoding is the contract.
    assert_equal "", captured[:body]
  end

  # The check-in path must never carry the registration credential: a leaked ping
  # key would otherwise carry management rights.
  def test_a_check_in_never_carries_the_api_key
    client, captured = client_capturing_request(ok)

    client.ping("daily_digest")

    refute_includes captured[:headers].values.join(" "), "sm_live_apikey"
  end

  # §12 "the URL encoder round-trips". CGI.escape and URI.encode_www_form_component
  # both give "my+task", which decodes as a literal "+" in a PATH segment — a 404
  # forever, while §5.1's route table still passes because none of its examples
  # contains a space. Asserted on the literal path string, since asserting on a
  # built URI object can hide the difference.
  def test_a_space_in_the_task_key_is_percent_encoded
    client, captured = client_capturing_request(ok)

    client.ping("my task")

    assert_equal "/api/v1/monitors/my%20task/pings", captured[:path]
  end

  # The route is declared `constraints: { registration_key: %r{[^/]+} }`, so an
  # unescaped slash routes to nothing at all.
  def test_a_slash_in_the_task_key_is_escaped
    client, captured = client_capturing_request(ok)

    client.ping("reports/daily")

    assert_equal "/api/v1/monitors/reports%2Fdaily/pings", captured[:path]
  end

  # --- What each state logs (§6.5). Since boot no longer syncs, these lines are
  # the only signal a misconfigured deploy produces. ---

  # Once per process, not once per job: one bad key must not print per run of
  # every job in the host app.
  def test_401_is_logged_once_loudly_and_never_names_the_credential
    client, = client_capturing_request(unauthorized)

    3.times { client.ping("daily_digest") }
    client.ping("weekly_report")

    assert_equal 1, @logger.errors.size
    assert_match(/401/, @logger.errors.first)
    refute_includes @logger.errors.first, "sm_ping_livekey"
  end

  # Once per TASK NAME: one unregistered task must not drown out another's line,
  # and each names the remedy.
  def test_404_is_logged_once_per_task_name_with_its_remedy
    client, = client_capturing_request(not_found)

    3.times { client.ping("daily_digest") }
    2.times { client.ping("weekly_report") }

    assert_equal 2, @logger.errors.size
    assert_match(/daily_digest/, @logger.errors[0])
    assert_match(/stablemate:sync/, @logger.errors[0])
    assert_match(/weekly_report/, @logger.errors[1])
  end

  def test_an_unexpected_4xx_is_logged_once_per_task_name_not_absorbed
    client, = client_capturing_request(too_many)

    2.times { client.ping("daily_digest") }
    client.ping("weekly_report")

    assert_equal 2, @logger.errors.size
    assert_match(/429/, @logger.errors[0])
    assert_match(/daily_digest/, @logger.errors[0])
  end

  # Transient states are absorbed by the grace period — reporting them as errors
  # would train the reader to ignore the two states that mean something.
  def test_5xx_and_transport_failures_log_no_error
    client, = client_capturing_request(server_error)
    client.ping("daily_digest")

    Stablemate.config.endpoint = "http://127.0.0.1:1"
    assert_equal :transient, Stablemate::Client.new(Stablemate.config).ping("daily_digest")

    assert_empty @logger.errors
  end

  # --- report_failure (§5.2): the SAME address and the same four states, with a
  # form-encoded status/message body. ---

  def test_report_failure_posts_form_encoded_status_and_message_to_the_same_address
    client, captured = client_capturing_request(ok)

    result = client.report_failure("daily_digest", message: "Boom: it broke")

    assert_equal :ok, result
    assert_equal "/api/v1/monitors/daily_digest/pings", captured[:path]
    assert_equal "status=1&message=Boom%3A+it+broke", captured[:body]
    assert_equal "application/x-www-form-urlencoded", captured[:headers]["Content-Type"]
    assert_equal "Bearer sm_ping_livekey", captured[:headers]["Authorization"]
  end

  def test_report_failure_truncates_the_message_client_side
    client, captured = client_capturing_request(ok)
    limit = Stablemate::Client::ERROR_MESSAGE_LIMIT

    client.report_failure("daily_digest", message: "e" * (limit + 500))

    sent = URI.decode_www_form(captured[:body]).to_h
    assert_equal "1", sent["status"]
    assert_equal "e" * limit, sent["message"]
  end

  def test_report_failure_classifies_like_ping
    client, = client_capturing_request(unauthorized)
    assert_equal :unauthorized, client.report_failure("daily_digest", message: "m")

    client, = client_capturing_request(not_found)
    assert_equal :unregistered, client.report_failure("daily_digest", message: "m")

    client, = client_capturing_request(too_many)
    assert_equal :refused, client.report_failure("daily_digest", message: "m")

    client, = client_capturing_request(server_error)
    assert_equal :transient, client.report_failure("daily_digest", message: "m")
  end

  # The never-raise contract, through the real transport. The endpoint is pointed
  # at an unroutable port on purpose: with the address derived from the key, a
  # default endpoint would send this test's request to the live server.
  def test_the_hot_path_swallows_transport_errors
    Stablemate.config.endpoint = "http://127.0.0.1:1"
    client = Stablemate::Client.new(Stablemate.config)

    assert_equal :transient, client.ping("daily_digest")
    assert_equal :transient, client.report_failure("daily_digest", message: "m")
  end

  # --- Registration, which is the OTHER credential and the other request shape:
  # #sync_monitors builds a JSON request object rather than posting a form. ---

  # Net::HTTP::Post carries the body, so the check-in recorder above (which
  # records #post's arguments) can't see it.
  class RecordingRequestHttp
    def initialize(response, captured)
      @response = response
      @captured = captured
    end

    def request(request)
      @captured.merge!(body: request.body, authorization: request["Authorization"])
      @response
    end
  end

  def sync_response(json = '{"monitors":[],"skipped":[]}')
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@body, json)
    response.instance_variable_set(:@read, true)
    response
  end

  def sync_capturing_request
    captured = {}
    factory = ->(_uri) { RecordingRequestHttp.new(sync_response, captured) }
    [ Stablemate::Client.new(Stablemate.config, http_factory: factory), captured ]
  end

  # Registration is the API key's ONLY job (§4): a leaked check-in credential
  # must carry no management rights, which only holds while the two paths read
  # different keys.
  def test_sync_authenticates_with_the_api_key
    client, captured = sync_capturing_request

    client.sync_monitors(app: "siftbox", monitors: [])

    assert_equal "Bearer sm_live_apikey", captured[:authorization]
  end

  # §6.1 — the flag and the key list ride together. The server distinguishes "no
  # prune" from "prune with no declared_keys" (every pre-0.2.0 gem, which retires
  # nothing at all), so an ordinary run must not send the pair in any form.
  def test_an_ordinary_run_sends_no_prune_and_no_declared_keys
    client, captured = sync_capturing_request

    client.sync_monitors(app: "siftbox", monitors: [ { registration_key: "a" } ])

    body = JSON.parse(captured[:body])
    assert_equal %w[app monitors], body.keys
  end

  def test_a_prune_run_sends_the_flag_and_the_keys
    client, captured = sync_capturing_request

    client.sync_monitors(app: "siftbox", monitors: [ { registration_key: "a" } ],
                         declared_keys: %w[a b], prune: true)

    body = JSON.parse(captured[:body])
    assert body["prune"]
    assert_equal %w[a b], body["declared_keys"]
  end

  # --- §6.6's two verification calls. `stablemate:install` proves BOTH
  # credentials before the user deploys anything, each on its own surface, and
  # neither call records a check-in — a synthetic ping would flip a monitor to
  # `up` for a job that has never run (§11). ---

  # Verification is a GET, so the check-in recorder (which records #post) cannot
  # see it, and the METHOD is part of the contract: §5.5 is a GET precisely
  # because it has no side effects.
  class RecordingGetHttp
    def initialize(response, captured)
      @response = response
      @captured = captured
    end

    def request(request)
      @captured.merge!(method: request.method, path: request.path,
                       authorization: request["Authorization"])
      @response
    end
  end

  def verify_capturing_request(response)
    captured = {}
    factory = ->(_uri) { RecordingGetHttp.new(response, captured) }
    [ Stablemate::Client.new(Stablemate.config, http_factory: factory), captured ]
  end

  # The ARGUMENT key, not the configured one: on a first install nothing has been
  # written for the config to have picked up, so a client reading config here
  # would verify a credential the user never pasted (and usually a nil one).
  def test_verifying_the_ping_key_gets_the_verify_endpoint_with_that_key
    client, captured = verify_capturing_request(ok)

    assert_equal :ok, client.verify_ping_key("sm_ping_pasted")

    assert_equal "GET", captured[:method]
    assert_equal "/api/v1/verify", captured[:path]
    assert_equal "Bearer sm_ping_pasted", captured[:authorization]
  end

  # The API key needs no endpoint of its own: listing monitors proves exactly the
  # credential registration uses, read-only.
  def test_verifying_the_api_key_lists_monitors_with_that_key
    client, captured = verify_capturing_request(ok)

    assert_equal :ok, client.verify_api_key("sm_live_pasted")

    assert_equal "GET", captured[:method]
    assert_equal "/api/v1/monitors", captured[:path]
    assert_equal "Bearer sm_live_pasted", captured[:authorization]
  end

  def test_a_401_is_a_rejection
    client, = verify_capturing_request(unauthorized)

    assert_equal :rejected, client.verify_ping_key("sm_ping_wrong")
    assert_equal :rejected, client.verify_api_key("sm_live_wrong")
  end

  # A server that never answered says NOTHING about the key. Calling this a
  # rejection sends the user to regenerate a pair that was fine, when the remedy
  # is the endpoint or the network — and a 404 is the same story: a Stablemate
  # too old to have §5.5 at all.
  def test_a_5xx_or_404_is_unreachable_rather_than_a_rejection
    client, = verify_capturing_request(server_error)
    assert_equal :unreachable, client.verify_ping_key("sm_ping_livekey")

    client, = verify_capturing_request(not_found)
    assert_equal :unreachable, client.verify_ping_key("sm_ping_livekey")
  end

  def test_a_transport_failure_is_unreachable
    Stablemate.config.endpoint = "http://127.0.0.1:1"
    client = Stablemate::Client.new(Stablemate.config)

    assert_equal :unreachable, client.verify_ping_key("sm_ping_livekey")
    assert_equal :unreachable, client.verify_api_key("sm_live_apikey")
  end
end
