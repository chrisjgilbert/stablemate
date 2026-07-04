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

  def classify(response)
    client.send(:classify, response)
  end

  def test_2xx_is_ok
    assert_equal :ok, classify(Net::HTTPOK.new("1.1", "200", "OK"))
  end

  def test_404_is_stale
    assert_equal :stale, classify(Net::HTTPNotFound.new("1.1", "404", "Not Found"))
  end

  def test_410_is_stale
    assert_equal :stale, classify(Net::HTTPGone.new("1.1", "410", "Gone"))
  end

  def test_429_is_error
    assert_equal :error, classify(Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests"))
  end

  def test_5xx_is_error
    assert_equal :error, classify(Net::HTTPInternalServerError.new("1.1", "500", "Error"))
  end
end
