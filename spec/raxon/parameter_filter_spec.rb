# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::ParameterFilter do
  subject(:filter) { described_class.new(%i[password token secret]) }

  describe "#filter" do
    it "redacts values whose key contains a filter term" do
      result = filter.filter(user: "amy", password: "hunter2", api_secret: "x")

      expect(result).to eq(user: "amy", password: "[FILTERED]", api_secret: "[FILTERED]")
    end

    it "redacts recursively through nested hashes and arrays" do
      input = {outer: {token: "abc", items: [{secret: "s"}, {ok: "v"}]}}

      result = filter.filter(input)

      expect(result).to eq(outer: {token: "[FILTERED]", items: [{secret: "[FILTERED]"}, {ok: "v"}]})
    end

    it "matches string keys too" do
      expect(filter.filter("password" => "p")).to eq("password" => "[FILTERED]")
    end

    it "supports Regexp filters" do
      regexp_filter = described_class.new([/\Acard_/])

      expect(regexp_filter.filter(card_number: "4111", account: "a")).to eq(card_number: "[FILTERED]", account: "a")
    end
  end

  describe "#filter_headers" do
    it "always redacts known credential headers" do
      headers = {"HTTP_AUTHORIZATION" => "Bearer x", "HTTP_COOKIE" => "s=1", "HTTP_ACCEPT" => "application/json"}

      result = filter.filter_headers(headers)

      expect(result).to eq(
        "HTTP_AUTHORIZATION" => "[FILTERED]",
        "HTTP_COOKIE" => "[FILTERED]",
        "HTTP_ACCEPT" => "application/json"
      )
    end
  end
end

RSpec.describe "Instrumentation payload filtering" do
  it "redacts sensitive params and headers before emitting the payload" do
    rack_request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/api/v1/login",
        :method => "POST",
        :params => {username: "amy", password: "hunter2"},
        "HTTP_AUTHORIZATION" => "Bearer sekret"
      )
    )
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.path "/api/v1/login"
    endpoint.operation :post
    request = Raxon::Request.new(rack_request, endpoint)
    response = Raxon::Response.new(endpoint)

    events = []
    ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    Raxon::Instrumentation.instrument_request(request, response, endpoint) do
      response.code = :ok
      response.body = {ok: true}
    end

    payload = events.first.payload
    expect(payload[:params][:password]).to eq("[FILTERED]")
    expect(payload[:params][:username]).to eq("amy")
    expect(payload[:headers]["HTTP_AUTHORIZATION"]).to eq("[FILTERED]")
  ensure
    ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
  end
end
