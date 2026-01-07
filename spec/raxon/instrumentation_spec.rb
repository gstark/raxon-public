# frozen_string_literal: true

require "spec_helper"
require "raxon/instrumentation"

RSpec.describe Raxon::Instrumentation do
  describe ".instrument_request" do
    it "emits start_processing.action_controller at request start" do
      rack_request = Rack::Request.new(Rack::MockRequest.env_for("/api/v1/users", method: "GET", params: {id: "123"}))
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/api/v1/users"
      endpoint.operation :get
      request = Raxon::Request.new(rack_request, endpoint)
      response = Raxon::Response.new(endpoint)

      events = []
      ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      Raxon::Instrumentation.instrument_request(request, response, endpoint) do
        response.code = :ok
        response.body = {success: true}
      end

      expect(events.size).to eq(1)
      expect(events.first.payload[:controller]).to eq("api/v1/users")
      expect(events.first.payload[:action]).to eq("GET")
      expect(events.first.payload[:method]).to eq("GET")
      expect(events.first.payload[:path]).to eq("/api/v1/users")
      expect(events.first.payload[:format]).to eq(:json)
    ensure
      ActiveSupport::Notifications.unsubscribe("start_processing.action_controller")
    end

    it "emits process_action.action_controller at request end" do
      rack_request = Rack::Request.new(Rack::MockRequest.env_for("/api/v1/users", method: "GET", params: {id: "123"}))
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/api/v1/users"
      endpoint.operation :get
      request = Raxon::Request.new(rack_request, endpoint)
      response = Raxon::Response.new(endpoint)

      events = []
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      Raxon::Instrumentation.instrument_request(request, response, endpoint) do
        response.code = :ok
        response.body = {success: true}
      end

      expect(events.size).to eq(1)
      expect(events.first.payload[:controller]).to eq("api/v1/users")
      expect(events.first.payload[:action]).to eq("GET")
      expect(events.first.payload[:status]).to eq(200)
      expect(events.first.payload[:view_runtime]).to eq(0)
      expect(events.first.payload[:db_runtime]).to be_a(Numeric)
    ensure
      ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
    end

    it "includes params in payload" do
      rack_request = Rack::Request.new(Rack::MockRequest.env_for("/api/v1/users", method: "GET", params: {id: "123"}))
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/api/v1/users"
      endpoint.operation :get
      request = Raxon::Request.new(rack_request, endpoint)
      response = Raxon::Response.new(endpoint)

      events = []
      ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      Raxon::Instrumentation.instrument_request(request, response, endpoint) do
        response.code = :ok
      end

      expect(events.first.payload[:params]).to be_a(Hash)
    ensure
      ActiveSupport::Notifications.unsubscribe("start_processing.action_controller")
    end

    it "returns the block result" do
      rack_request = Rack::Request.new(Rack::MockRequest.env_for("/api/v1/users", method: "GET", params: {id: "123"}))
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/api/v1/users"
      endpoint.operation :get
      request = Raxon::Request.new(rack_request, endpoint)
      response = Raxon::Response.new(endpoint)

      result = Raxon::Instrumentation.instrument_request(request, response, endpoint) do
        response.code = :ok
        :block_result
      end

      expect(result).to eq(:block_result)
    end

    it "propagates exceptions while still emitting process_action" do
      rack_request = Rack::Request.new(Rack::MockRequest.env_for("/api/v1/users", method: "GET", params: {id: "123"}))
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/api/v1/users"
      endpoint.operation :get
      request = Raxon::Request.new(rack_request, endpoint)
      response = Raxon::Response.new(endpoint)

      events = []
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      expect {
        Raxon::Instrumentation.instrument_request(request, response, endpoint) do
          raise StandardError, "test error"
        end
      }.to raise_error(StandardError, "test error")

      expect(events.size).to eq(1)
      expect(events.first.payload[:exception]).to eq(["StandardError", "test error"])
    ensure
      ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
    end
  end

  describe ".controller_from_endpoint" do
    it "extracts path without leading slash" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/api/v1/users/:id"

      result = Raxon::Instrumentation.controller_from_endpoint(endpoint)

      expect(result).to eq("api/v1/users/:id")
    end

    it "handles root path" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.path "/"

      result = Raxon::Instrumentation.controller_from_endpoint(endpoint)

      expect(result).to eq("")
    end
  end
end
