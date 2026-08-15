require "test_helper"

# Phase 3 of the cutover (v1-scope §8.1): the token-in-the-URL check-in path is
# deleted, now that gem 0.2.0 addresses monitors locally and authenticates by
# header. This file is the negative of the phase-1 cutover test it replaces —
# that one proved the old path still worked so the phases could be separated;
# this one proves it is gone.
#
# The deletion is what §3.2 buys: a credential that never reaches a log line, and
# a check-in that cannot be fired by anything that merely follows a link.
class RemovedPingSurfaceTest < ActionDispatch::IntegrationTest
  setup do
    @monitor = monitors(:up)
    @alice = users(:alice)
  end

  # --- The public endpoint -----------------------------------------------------

  # Both verbs, because the old route was `via: %i[get post]` and the GET arm is
  # the one §3.2 calls out: link-followers (chat previews, mail prefetch,
  # scanners) could resolve an incident and send a "recovered" email.
  test "the old ping path is routable by nothing, on either verb" do
    assert_not respond_to?(:ping_path)

    %i[get post].each do |verb|
      assert_raises(ActionController::RoutingError, "#{verb.upcase} /ping/:token still routes") do
        Rails.application.routes.recognize_path("/ping/sometoken", method: verb)
      end
    end
  end

  test "a request to the old ping path 404s instead of checking anything in" do
    assert_no_difference -> { @monitor.ping_events.count } do
      get "/ping/anything"
      assert_response :not_found
    end
    assert_equal "up", @monitor.reload.status
  end

  # --- The rotation controllers ------------------------------------------------

  test "neither rotation route survives" do
    assert_not respond_to?(:monitor_ping_token_path)
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/monitors/#{@monitor.id}/ping_token", method: :patch)
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/api/v1/monitors/#{@monitor.id}/rotate", method: :post)
    end
  end

  # --- The serializers ---------------------------------------------------------

  # The column is gone, so a payload that still advertised a ping URL could only
  # be advertising a dead one. All three payloads that carried it are checked,
  # because they were built by three different call sites.
  test "no /api/v1 payload advertises a ping url" do
    key = ApiKey.issue(project: @alice.projects.sole, name: "CI").last
    headers = { "Authorization" => "Bearer #{key}" }

    get api_v1_monitors_path, headers: headers
    assert_response :success
    assert_not response.parsed_body.fetch("monitors").any? { |m| m.key?("ping_url") }

    get api_v1_monitor_path(@monitor), headers: headers
    assert_response :success
    assert_not response.parsed_body.key?("ping_url")
  end

  test "the sync payload advertises no ping url" do
    key = ApiKey.issue(project: @alice.projects.sole, name: "CI").last

    post sync_api_v1_monitors_path,
         params: { app: "my-app", monitors: [ { registration_key: "nightly", name: "nightly",
                                                expected_interval_seconds: 3600,
                                                grace_period_seconds: 300 } ] }.to_json,
         headers: { "Authorization" => "Bearer #{key}", "Content-Type" => "application/json" }

    assert_response :success
    registered = response.parsed_body.fetch("monitors")
    assert_equal 1, registered.size
    assert_not registered.first.key?("ping_url")
  end

  # --- The column and its concern ---------------------------------------------

  test "the ping_token column and its generator are gone" do
    assert_not Monitoring::Monitor.column_names.include?("ping_token")
    assert_not Monitoring::Monitor.respond_to?(:generate_ping_token)
    assert_not @monitor.respond_to?(:rotate_ping_token!)
  end
end
