# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Response do
  describe "#initialize" do
    it "initializes with default values" do
      response = Raxon::Response.new

      expect(response.rack_response).to be_a(Rack::Response)
      expect(response.status_code).to eq(200)
      expect(response.halted?).to be(false)
      expect(response.runnable?).to be(true)
    end

    it "initializes with an endpoint" do
      endpoint = Raxon::OpenApi::Endpoint.new
      response = Raxon::Response.new(endpoint)

      expect(response.status_code).to eq(200)
    end
  end

  describe "#code" do
    it "sets status code with symbol" do
      response = Raxon::Response.new

      response.code = :not_found

      expect(response.status_code).to eq(404)
    end

    it "sets status code with integer" do
      response = Raxon::Response.new

      response.code = 201

      expect(response.status_code).to eq(201)
    end

    it "raises error for unknown symbol" do
      response = Raxon::Response.new

      expect {
        response.code = :unknown_status
      }.to raise_error(ArgumentError, /Unknown status code symbol/)
    end

    it "supports all 1xx status codes" do
      response = Raxon::Response.new

      response.code = :continue
      expect(response.status_code).to eq(100)

      response.code = :switching_protocols
      expect(response.status_code).to eq(101)

      response.code = :processing
      expect(response.status_code).to eq(102)

      response.code = :early_hints
      expect(response.status_code).to eq(103)
    end

    it "supports all 2xx status codes" do
      response = Raxon::Response.new

      response.code = :ok
      expect(response.status_code).to eq(200)

      response.code = :created
      expect(response.status_code).to eq(201)

      response.code = :accepted
      expect(response.status_code).to eq(202)

      response.code = :no_content
      expect(response.status_code).to eq(204)

      response.code = :partial_content
      expect(response.status_code).to eq(206)
    end

    it "supports all 3xx status codes" do
      response = Raxon::Response.new

      response.code = :moved_permanently
      expect(response.status_code).to eq(301)

      response.code = :found
      expect(response.status_code).to eq(302)

      response.code = :see_other
      expect(response.status_code).to eq(303)

      response.code = :not_modified
      expect(response.status_code).to eq(304)

      response.code = :temporary_redirect
      expect(response.status_code).to eq(307)

      response.code = :permanent_redirect
      expect(response.status_code).to eq(308)
    end

    it "supports all 4xx status codes" do
      response = Raxon::Response.new

      response.code = :bad_request
      expect(response.status_code).to eq(400)

      response.code = :unauthorized
      expect(response.status_code).to eq(401)

      response.code = :forbidden
      expect(response.status_code).to eq(403)

      response.code = :not_found
      expect(response.status_code).to eq(404)

      response.code = :unprocessable_entity
      expect(response.status_code).to eq(422)

      response.code = :too_many_requests
      expect(response.status_code).to eq(429)
    end

    it "supports all 5xx status codes" do
      response = Raxon::Response.new

      response.code = :internal_server_error
      expect(response.status_code).to eq(500)

      response.code = :not_implemented
      expect(response.status_code).to eq(501)

      response.code = :bad_gateway
      expect(response.status_code).to eq(502)

      response.code = :service_unavailable
      expect(response.status_code).to eq(503)

      response.code = :gateway_timeout
      expect(response.status_code).to eq(504)
    end
  end

  describe "#body= and #body" do
    it "sets and gets hash body" do
      response = Raxon::Response.new

      response.body = {foo: "bar"}

      expect(response.body).to eq({foo: "bar"})
    end

    it "sets and gets string body" do
      response = Raxon::Response.new

      response.body = "plain text"

      expect(response.body).to eq("plain text")
    end

    it "sets and gets array body" do
      response = Raxon::Response.new

      response.body = [1, 2, 3]

      expect(response.body).to eq([1, 2, 3])
    end
  end

  describe "#html_body=" do
    it "sets HTML body and content-type" do
      response = Raxon::Response.new

      response.html_body = "<h1>Hello</h1>"

      expect(response.body).to eq("<h1>Hello</h1>")

      _status, headers, _body = response.to_rack
      expect(headers["content-type"]).to eq("text/html")
    end
  end

  describe "#html" do
    it "renders ERB template with locals" do
      endpoint = Raxon::OpenApi::Endpoint.new
      template = ERB.new("<h1>Hello <%= name %></h1>")
      endpoint.erb_template = template

      response = Raxon::Response.new(endpoint)

      result = response.html(name: "World")

      expect(result).to eq("<h1>Hello World</h1>")
    end

    it "raises error when no template configured" do
      response = Raxon::Response.new

      expect {
        response.html(name: "World")
      }.to raise_error(Raxon::Error, /Template not found/)
    end

    it "raises error when endpoint has no template" do
      endpoint = Raxon::OpenApi::Endpoint.new
      response = Raxon::Response.new(endpoint)

      expect {
        response.html(name: "World")
      }.to raise_error(Raxon::Error, /Template not found/)
    end
  end

  describe "#halt" do
    it "marks response as halted" do
      response = Raxon::Response.new

      begin
        response.halt
      rescue Raxon::HaltException
        # Exception raised as expected
      end

      expect(response.halted?).to be(true)
      expect(response.runnable?).to be(false)
    end
  end

  describe "#runnable?" do
    it "returns true by default" do
      response = Raxon::Response.new

      expect(response.runnable?).to be(true)
    end

    it "returns false after halt" do
      response = Raxon::Response.new

      begin
        response.halt
      rescue Raxon::HaltException
        # Exception raised as expected
      end

      expect(response.runnable?).to be(false)
    end
  end

  describe "#halted?" do
    it "returns false by default" do
      response = Raxon::Response.new

      expect(response.halted?).to be(false)
    end

    it "returns true after halt" do
      response = Raxon::Response.new

      begin
        response.halt
      rescue Raxon::HaltException
        # Exception raised as expected
      end

      expect(response.halted?).to be(true)
    end
  end

  describe "#to_rack" do
    it "converts to Rack response array" do
      response = Raxon::Response.new
      response.body = {success: true}

      status, headers, body = response.to_rack

      expect(status).to eq(200)
      expect(headers).to be_a(Hash)
      expect(body).to be_a(Array)
    end

    it "serializes hash body to JSON" do
      response = Raxon::Response.new
      response.body = {foo: "bar"}

      _status, _headers, body = response.to_rack

      expect(body.first).to eq('{"foo":"bar"}')
    end

    it "serializes array body to JSON" do
      response = Raxon::Response.new
      response.body = [1, 2, 3]

      _status, _headers, body = response.to_rack

      expect(body.first).to eq("[1,2,3]")
    end

    it "uses string body as-is" do
      response = Raxon::Response.new
      response.body = "plain text"

      _status, _headers, body = response.to_rack

      expect(body.first).to eq("plain text")
    end

    it "returns empty body when no body set" do
      response = Raxon::Response.new

      _status, _headers, body = response.to_rack

      expect(body).to eq([])
    end

    it "clears existing body before writing new content" do
      response = Raxon::Response.new
      response.body = {foo: "bar"}

      # Call to_rack twice to test body clearing
      response.to_rack
      _status, _headers, body = response.to_rack

      expect(body.first).to eq('{"foo":"bar"}')
    end
  end

  describe "#status_code" do
    it "returns current status code" do
      response = Raxon::Response.new

      expect(response.status_code).to eq(200)

      response.code = :not_found
      expect(response.status_code).to eq(404)
    end
  end

  describe "private methods" do
    describe "#header" do
      it "sets response header" do
        response = Raxon::Response.new

        response.send(:header, "X-Custom-Header", "value")

        _status, headers, _body = response.to_rack
        expect(headers["X-Custom-Header"]).to eq("value")
      end
    end

    describe "#headers" do
      it "returns response headers" do
        response = Raxon::Response.new

        headers = response.send(:headers)

        expect(headers).to be_a(Hash)
        expect(headers["content-type"]).to eq("application/json")
      end
    end

    describe "#write" do
      it "writes to response body" do
        response = Raxon::Response.new

        response.send(:write, "Hello ")
        response.send(:write, "World")

        _status, _headers, body = response.to_rack
        # When body is written directly, it creates an array with each write
        expect(body.join).to eq("Hello World")
      end
    end

    describe "#set_cookie" do
      it "sets a cookie" do
        response = Raxon::Response.new

        response.send(:set_cookie, "session", value: "abc123", path: "/")

        _status, headers, _body = response.to_rack
        expect(headers["set-cookie"]).to include("session=abc123")
      end
    end

    describe "#delete_cookie" do
      it "deletes a cookie" do
        response = Raxon::Response.new

        response.send(:set_cookie, "session", value: "abc123")
        response.send(:delete_cookie, "session")

        _status, headers, _body = response.to_rack
        # Rack returns an array of set-cookie headers
        cookie_headers = headers["set-cookie"]
        expect(cookie_headers).to be_a(Array)
        expect(cookie_headers.last).to include("max-age=0")
      end

      it "accepts options hash" do
        response = Raxon::Response.new

        response.send(:set_cookie, "session", value: "abc123")
        response.send(:delete_cookie, "session", path: "/", domain: "example.com")

        _status, headers, _body = response.to_rack
        cookie_headers = headers["set-cookie"]
        expect(cookie_headers).to be_a(Array)
        expect(cookie_headers.last).to include("max-age=0")
        expect(cookie_headers.last).to include("domain=example.com")
      end
    end

    describe "#redirect" do
      it "sets redirect location and status" do
        response = Raxon::Response.new

        response.send(:redirect, "/login", 302)

        status, headers, _body = response.to_rack
        expect(status).to eq(302)
        expect(headers["location"]).to eq("/login")
      end

      it "defaults to 302 status" do
        response = Raxon::Response.new

        response.send(:redirect, "/login")

        status, _headers, _body = response.to_rack
        expect(status).to eq(302)
      end
    end
  end
end
