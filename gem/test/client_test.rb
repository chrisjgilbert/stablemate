# frozen_string_literal: true

require_relative "test_helper"
require "net/http"

# WU-8 (M2) — Client#ping must classify the response, not report every HTTP reply
# as a delivered ping. A 404/410 (rotated token) is :stale; other non-2xx is a
# transient :error; only 2xx is :ok.
class ClientTest < StablemateTest
  def client
    Stablemate::Client.new(Stablemate.config)
  end

  # Classification is asserted through #ping, the public entry point it exists to
  # serve, rather than by reaching for the private #classify: calling the private
  # method proves the case statement works but not that #ping consults it, so a
  # #ping that stopped classifying at all would still have passed.
  def ping_status(response)
    client_capturing_request(response).first.ping("https://sm.test/ping/abc")
  end

  def test_2xx_is_ok
    assert_equal :ok, ping_status(Net::HTTPOK.new("1.1", "200", "OK"))
  end

  def test_404_is_stale
    assert_equal :stale, ping_status(Net::HTTPNotFound.new("1.1", "404", "Not Found"))
  end

  def test_410_is_stale
    assert_equal :stale, ping_status(Net::HTTPGone.new("1.1", "410", "Gone"))
  end

  def test_429_is_error
    assert_equal :error, ping_status(Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests"))
  end

  def test_5xx_is_error
    assert_equal :error, ping_status(Net::HTTPInternalServerError.new("1.1", "500", "Error"))
  end

  # --- report_failure (spec §7): POST to the SAME ping URL, form-encoded
  # status=1&message=…, same classification as #ping, never raises. ---

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

  def test_report_failure_posts_form_encoded_status_and_message_to_the_ping_url
    c, captured = client_capturing_request(Net::HTTPOK.new("1.1", "200", "OK"))

    result = c.report_failure("https://sm.test/ping/abc", message: "Boom: it broke")

    assert_equal :ok, result
    # The same ping URL — not a /fail suffix.
    assert_equal "/ping/abc", captured[:path]
    assert_equal "status=1&message=Boom%3A+it+broke", captured[:body]
    assert_equal "application/x-www-form-urlencoded", captured[:headers]["Content-Type"]
  end

  def test_report_failure_truncates_the_message_client_side
    c, captured = client_capturing_request(Net::HTTPOK.new("1.1", "200", "OK"))
    limit = Stablemate::Client::ERROR_MESSAGE_LIMIT

    c.report_failure("https://sm.test/ping/abc", message: "e" * (limit + 500))

    sent = URI.decode_www_form(captured[:body]).to_h
    assert_equal "1", sent["status"]
    assert_equal "e" * limit, sent["message"]
  end

  def test_report_failure_classifies_stale_and_error_like_ping
    c, = client_capturing_request(Net::HTTPNotFound.new("1.1", "404", "Not Found"))
    assert_equal :stale, c.report_failure("https://sm.test/ping/abc", message: "m")

    c, = client_capturing_request(Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests"))
    assert_equal :error, c.report_failure("https://sm.test/ping/abc", message: "m")
  end

  def test_report_failure_swallows_transport_errors
    # An unroutable URL must not raise — same never-raise contract as #ping.
    assert_equal :error, client.report_failure("http://127.0.0.1:1/ping/none", message: "m")
  end
end
