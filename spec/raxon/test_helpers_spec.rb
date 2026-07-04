# frozen_string_literal: true

require "spec_helper"
require "raxon/test/rspec"

RSpec.describe Raxon::Test do
  include Raxon::Test::Methods

  before do
    define_route("routes/users/get.rb") do |endpoint|
      endpoint.query_param :page, type: :integer
      endpoint.response 200, type: :object do |response|
        response.property :users, type: :array, of: :string
        response.property :page, type: :integer, required: false, nullable: true
      end
      endpoint.handler do |request, response, metadata|
        response.ok users: ["alice"], page: request.params[:page]
      end
    end

    define_route("routes/users/post.rb") do |endpoint|
      endpoint.body type: :object do |body|
        body.property :name, type: :string
      end
      endpoint.response 201, type: :object do |response|
        response.property :name, type: :string
      end
      endpoint.handler do |request, response, metadata|
        response.created name: request.params[:name]
      end
    end
  end

  describe "request helpers" do
    it "performs GET requests with query params" do
      get "/users", params: {page: 2}

      expect(last_response.status).to eq(200)
      expect(last_response.json).to eq({"users" => ["alice"], "page" => 2})
    end

    it "performs POST requests with a JSON body" do
      post "/users", json: {name: "bob"}

      expect(last_response.status).to eq(201)
      expect(last_response.json).to eq({"name" => "bob"})
    end

    it "performs POST requests with form params" do
      post "/users", params: {name: "carol"}

      expect(last_response.status).to eq(201)
      expect(last_response.json["name"]).to eq("carol")
    end

    it "performs POST requests with a raw body" do
      define_route("routes/raw/post.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          body = request.rack_request.body
          body.rewind
          response.ok length: body.read.length
        end
      end

      post "/raw", body: "12345"

      expect(last_response.json).to eq({"length" => 5})
    end

    it "appends query params when a JSON body is present" do
      define_route("routes/echo/post.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok query: request.query_params, body: request.body_params
        end
      end

      post "/echo?a=1", params: {b: "2"}, json: {c: 3}

      expect(last_response.json).to eq({"query" => {"a" => "1", "b" => "2"}, "body" => {"c" => 3}})
    end

    it "builds the query string when the path has none" do
      define_route("routes/echo/post.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok query: request.query_params
        end
      end

      post "/echo", params: {b: "2"}, json: {c: 3}

      expect(last_response.json).to eq({"query" => {"b" => "2"}})
    end

    it "normalizes friendly header names" do
      define_route("routes/headers/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok api_key: request.header("HTTP_X_API_KEY"), content_type: request.content_type
        end
      end

      get "/headers", headers: {"X-API-Key" => "secret", "Content-Type" => "text/plain"}

      expect(last_response.json).to eq({"api_key" => "secret", "content_type" => "text/plain"})
    end

    it "passes raw HTTP_ header names through unchanged" do
      define_route("routes/headers/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok api_key: request.header("HTTP_X_API_KEY")
        end
      end

      get "/headers", headers: {"HTTP_X_API_KEY" => "raw"}

      expect(last_response.json).to eq({"api_key" => "raw"})
    end

    it "supports HEAD requests" do
      head "/users"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("")
    end

    it "parses JSON with symbolized names on request" do
      get "/users"

      expect(last_response.json(symbolize_names: true)).to eq({users: ["alice"], page: nil})
    end

    it "fetches headers case-insensitively" do
      get "/users"

      expect(last_response["Content-Type"]).to eq("application/json")
    end

    it "raises when last_response is read before any request" do
      expect { last_response }.to raise_error(Raxon::Error, /No request has been made/)
    end
  end

  describe "conform_to_response_schema matcher" do
    it "passes when the body matches the declared schema" do
      get "/users", params: {page: 1}

      expect(last_response).to conform_to_response_schema
      expect(last_response).to conform_to_response_schema(200)
    end

    it "fails when the status does not match the expected status" do
      get "/users"

      expect {
        expect(last_response).to conform_to_response_schema(201)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected status 201, got 200/)
    end

    it "fails when no route matches the request" do
      get "/missing"

      expect {
        expect(last_response).to conform_to_response_schema
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /no route matches GET \/missing/)
    end

    it "fails when the endpoint declares no schema for the status" do
      define_route("routes/bare/get.rb") do |endpoint|
        endpoint.handler { |request, response, metadata| response.ok anything: true }
      end

      get "/bare"

      expect {
        expect(last_response).to conform_to_response_schema
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /declares no response schema for status 200/)
    end

    it "fails when the body does not conform to the schema" do
      define_route("routes/broken/get.rb") do |endpoint|
        endpoint.validate_response false
        endpoint.response 200, type: :object do |response|
          response.property :count, type: :integer
        end
        endpoint.handler { |request, response, metadata| response.ok count: "not a number" }
      end

      get "/broken"

      expect {
        expect(last_response).to conform_to_response_schema
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /does not conform to the declared schema for status 200/)
    end

    it "fails when the body is not JSON" do
      define_route("routes/plain/get.rb") do |endpoint|
        endpoint.validate_response false
        endpoint.response 200, type: :object do |response|
          response.property :ok, type: :boolean
        end
        endpoint.handler do |request, response, metadata|
          response.body = "plain text"
        end
      end

      get "/plain"

      expect {
        expect(last_response).to conform_to_response_schema
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /not valid JSON/)
    end
  end

  describe "#app" do
    it "can be overridden" do
      @raxon_test_app = ->(env) { [418, {"content-type" => "text/plain"}, ["teapot"]] }

      get "/anything"

      expect(last_response.status).to eq(418)
      expect(last_response.body).to eq("teapot")
    end

    it "closes closeable response bodies" do
      body = Class.new {
        attr_reader :closed

        def each
          yield "streamed"
        end

        def close
          @closed = true
        end
      }.new
      @raxon_test_app = ->(env) { [200, {"content-type" => "text/plain"}, body] }

      get "/stream"

      expect(last_response.body).to eq("streamed")
      expect(body.closed).to be(true)
    end
  end
end
