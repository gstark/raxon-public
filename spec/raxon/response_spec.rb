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

  describe "convenience response methods" do
    describe "#ok" do
      it "sets a 200 OK response with keyword body" do
        response = Raxon::Response.new

        result = response.ok(success: true)

        expect(result).to eq(response)
        expect(response.status_code).to eq(200)
        expect(response.body).to eq(success: true)
      end

      it "sets a 200 OK response with positional body" do
        body = {users: []}
        response = Raxon::Response.new

        response.ok(body)

        expect(response.status_code).to eq(200)
        expect(response.body).to eq(body)
      end
    end

    describe "#created" do
      it "sets a 201 Created response with resource body" do
        user = {id: 1, name: "Ada"}
        response = Raxon::Response.new

        result = response.created(user)

        expect(result).to eq(response)
        expect(response.status_code).to eq(201)
        expect(response.body).to eq(user)
      end

      it "sets a 201 Created response with keyword body" do
        response = Raxon::Response.new

        response.created(id: 1, name: "Ada")

        expect(response.status_code).to eq(201)
        expect(response.body).to eq(id: 1, name: "Ada")
      end
    end

    describe "#no_content" do
      it "sets a 204 No Content response with nil body" do
        response = Raxon::Response.new
        response.body = {previous: "body"}

        result = response.no_content

        expect(result).to eq(response)
        expect(response.status_code).to eq(204)
        expect(response.body).to be_nil
      end

      it "renders an empty rack body" do
        response = Raxon::Response.new

        response.no_content
        status, _headers, body = response.to_rack

        expect(status).to eq(204)
        expect(body).to eq([])
      end
    end

    describe "#not_found" do
      it "sets a 404 Not Found response with keyword body" do
        response = Raxon::Response.new

        result = response.not_found(error: "User not found")

        expect(result).to eq(response)
        expect(response.status_code).to eq(404)
        expect(response.body).to eq(error: "User not found")
      end

      it "sets a default 404 error body when no body is provided" do
        response = Raxon::Response.new

        response.not_found

        expect(response.status_code).to eq(404)
        expect(response.body).to eq(error: "Not Found")
      end
    end

    describe "#error" do
      it "sets an error response with message and status symbol" do
        response = Raxon::Response.new

        result = response.error("Unauthorized", status: :unauthorized)

        expect(result).to eq(response)
        expect(response.status_code).to eq(401)
        expect(response.body).to eq(error: "Unauthorized")
      end

      it "defaults to 400 Bad Request" do
        response = Raxon::Response.new

        response.error("Invalid request")

        expect(response.status_code).to eq(400)
        expect(response.body).to eq(error: "Invalid request")
      end

      it "accepts numeric status codes" do
        response = Raxon::Response.new

        response.error("Conflict", status: 409)

        expect(response.status_code).to eq(409)
        expect(response.body).to eq(error: "Conflict")
      end
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
    it "renders template with locals" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.erb_template = Raxon::Template.new("<h1>Hello <%= name %></h1>")

      response = Raxon::Response.new(endpoint)

      result = response.html(name: "World")

      expect(result).to eq("<h1>Hello World</h1>")
    end

    it "HTML-escapes locals to prevent XSS" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.erb_template = Raxon::Template.new("<h1>Hello <%= name %></h1>")

      response = Raxon::Response.new(endpoint)

      result = response.html(name: "<script>alert(1)</script>")

      expect(result).to eq("<h1>Hello &lt;script&gt;alert(1)&lt;/script&gt;</h1>")
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

    it "sets code and body before halting" do
      response = Raxon::Response.new

      begin
        response.halt code: :unauthorized, body: {error: "Invalid API key"}
      rescue Raxon::HaltException
        # Exception raised as expected
      end

      expect(response.status_code).to eq(401)
      expect(response.body).to eq({error: "Invalid API key"})
      expect(response.halted?).to be(true)
    end

    it "sets numeric code before halting" do
      response = Raxon::Response.new

      begin
        response.halt code: 418
      rescue Raxon::HaltException
        # Exception raised as expected
      end

      expect(response.status_code).to eq(418)
      expect(response.halted?).to be(true)
    end

    it "allows halting with a nil body" do
      response = Raxon::Response.new
      response.body = {previous: "body"}

      begin
        response.halt body: nil
      rescue Raxon::HaltException
        # Exception raised as expected
      end

      expect(response.body).to be_nil
      expect(response.halted?).to be(true)
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

  describe "config.body_serializer" do
    # A stand-in for an Alba resource: an object that knows how to turn itself
    # into JSON-ready data.
    let(:serializer_class) do
      Struct.new(:data) do
        def serializable_hash = data
      end
    end

    # A before hook, not around: spec_helper resets configuration in its own
    # before(:each), which runs after around hooks open and would wipe this.
    before do
      klass = serializer_class
      Raxon.configuration.body_serializer = ->(body) {
        body.is_a?(klass) ? body.serializable_hash : body
      }
    end

    it "encodes a returned serializer object as its data" do
      response = Raxon::Response.new
      response.body = serializer_class.new({id: 7, name: "Ada"})

      _status, _headers, body = response.to_rack

      expect(body.first).to eq('{"id":7,"name":"Ada"}')
    end

    it "encodes a collection serializer as an array" do
      response = Raxon::Response.new
      response.body = serializer_class.new([{id: 1}, {id: 2}])

      _status, _headers, body = response.to_rack

      expect(body.first).to eq('[{"id":1},{"id":2}]')
    end

    it "exposes the coerced data through #serializable_body for validation" do
      response = Raxon::Response.new
      response.body = serializer_class.new({id: 7})

      expect(response.serializable_body).to eq({id: 7})
    end

    it "leaves a plain hash body untouched" do
      response = Raxon::Response.new
      response.body = {plain: true}

      expect(response.serializable_body).to eq({plain: true})
    end

    it "coerces a serializer nested under a key" do
      response = Raxon::Response.new
      response.body = {conversation: serializer_class.new({id: 7})}

      expect(response.serializable_body).to eq({conversation: {id: 7}})
    end

    it "coerces serializers inside an array" do
      response = Raxon::Response.new
      response.body = {items: [serializer_class.new({id: 1}), serializer_class.new({id: 2})]}

      expect(response.serializable_body).to eq({items: [{id: 1}, {id: 2}]})
    end

    it "coerces a serializer returned inside another serializer's data" do
      response = Raxon::Response.new
      response.body = serializer_class.new({owner: serializer_class.new({id: 9})})

      expect(response.serializable_body).to eq({owner: {id: 9}})
    end

    it "returns the same hash object when nothing was coerced" do
      response = Raxon::Response.new
      body = {a: 1, b: {c: [2, 3]}}
      response.body = body

      expect(response.serializable_body).to be(body)
    end

    it "reflects a body an after block rewrote, since it is not memoized" do
      response = Raxon::Response.new
      response.body = serializer_class.new({first: 1})
      expect(response.serializable_body).to eq({first: 1})

      response.body = serializer_class.new({second: 2})
      expect(response.serializable_body).to eq({second: 2})
    end

    it "is identity when no serializer is configured" do
      Raxon.configuration.body_serializer = nil
      response = Raxon::Response.new
      response.body = {untouched: true}

      expect(response.serializable_body).to eq({untouched: true})
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

  describe "public header and Rack response helpers" do
    describe "#header" do
      it "sets response header" do
        response = Raxon::Response.new

        response.header "X-Custom-Header", "value"

        _status, headers, _body = response.to_rack
        expect(headers["X-Custom-Header"]).to eq("value")
      end
    end

    describe "#headers" do
      it "returns response headers" do
        response = Raxon::Response.new

        headers = response.headers

        expect(headers).to be_a(Hash)
        expect(headers["content-type"]).to eq("application/json")
      end
    end

    describe "#write" do
      it "writes to response body" do
        response = Raxon::Response.new

        response.write "Hello "
        response.write "World"

        _status, _headers, body = response.to_rack
        # When body is written directly, it creates an array with each write
        expect(body.join).to eq("Hello World")
      end
    end

    describe "#set_cookie" do
      it "sets a cookie" do
        response = Raxon::Response.new

        response.set_cookie "session", value: "abc123", path: "/"

        _status, headers, _body = response.to_rack
        expect(headers["set-cookie"]).to include("session=abc123")
      end
    end

    describe "#delete_cookie" do
      it "deletes a cookie" do
        response = Raxon::Response.new

        response.set_cookie "session", value: "abc123"
        response.delete_cookie "session"

        _status, headers, _body = response.to_rack
        # Rack returns an array of set-cookie headers
        cookie_headers = headers["set-cookie"]
        expect(cookie_headers).to be_a(Array)
        expect(cookie_headers.last).to include("max-age=0")
      end

      it "accepts options hash" do
        response = Raxon::Response.new

        response.set_cookie "session", value: "abc123"
        response.delete_cookie "session", path: "/", domain: "example.com"

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

        response.redirect "/login", 302

        status, headers, _body = response.to_rack
        expect(status).to eq(302)
        expect(headers["location"]).to eq("/login")
      end

      it "defaults to 302 status" do
        response = Raxon::Response.new

        response.redirect "/login"

        status, _headers, _body = response.to_rack
        expect(status).to eq(302)
      end
    end
  end
end

RSpec.describe Raxon::Response, "rack-backed state" do
  it "reads code from the plain status before the Rack response materializes" do
    response = Raxon::Response.new
    response.code = :created

    expect(response.code).to eq(201)
  end

  it "reads code from the Rack response once materialized" do
    response = Raxon::Response.new
    response.rack_response
    response.code = :accepted

    expect(response.code).to eq(202)
  end

  it "writes headers to the Rack response once materialized" do
    response = Raxon::Response.new
    response.rack_response
    response.header "X-Request-Id", "abc-123"

    expect(response.headers["X-Request-Id"]).to eq("abc-123")

    _status, headers, _body = response.to_rack
    expect(headers["X-Request-Id"]).to eq("abc-123")
  end

  it "replaces any Rack body content with the custom body on to_rack" do
    response = Raxon::Response.new
    response.rack_response.write("stale")
    response.body = {fresh: true}

    _status, _headers, body = response.to_rack

    expect(body.join).to eq({fresh: true}.to_json)
  end
end

RSpec.describe Raxon::Response, "non-clearable Rack bodies" do
  it "appends the custom body when the Rack body cannot be cleared" do
    streaming_body = Class.new do
      def initialize = @chunks = ["streamed"]

      def each(&block) = @chunks.each(&block)

      def <<(chunk) = @chunks << chunk
    end.new

    response = Raxon::Response.new
    response.rack_response.body = streaming_body
    response.body = {fresh: true}

    _status, _headers, body = response.to_rack

    chunks = []
    body.each { |chunk| chunks << chunk }
    expect(chunks).to eq(["streamed", {fresh: true}.to_json])
  end
end
