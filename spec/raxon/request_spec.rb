# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Request do
  describe "#initialize" do
    it "initializes with a Rack::Request" do
      rack_request = Rack::MockRequest.env_for("/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.rack_request).to eq(rack_req)
      expect(request.endpoint).to be_nil
      expect(request.validation_errors).to be_nil
      expect(request.json_parse_error).to be(false)
    end

    it "initializes with an endpoint" do
      rack_request = Rack::MockRequest.env_for("/test")
      rack_req = Rack::Request.new(rack_request)
      endpoint = Raxon::OpenApi::Endpoint.new

      request = Raxon::Request.new(rack_req, endpoint)

      expect(request.endpoint).to eq(endpoint)
    end
  end

  describe "source-specific params" do
    it "exposes query parameters without body or path parameters" do
      rack_request = Rack::MockRequest.env_for(
        "/users/123?filter=active&shared=query",
        :method => "POST",
        :input => {shared: "body", name: "Ada"}.to_json,
        "CONTENT_TYPE" => "application/json"
      )
      rack_request["router.params"] = {"id" => "123", "shared" => "path"}
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.query_params).to eq(filter: "active", shared: "query")
    end

    it "exposes path parameters from router params with symbol keys" do
      rack_request = Rack::MockRequest.env_for("/users/123?include=posts")
      rack_request["router.params"] = {"id" => "123"}
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.path_params).to eq(id: "123")
    end

    it "returns an empty hash for path parameters when no route params are present" do
      request = Raxon::Request.new(Rack::Request.new(Rack::MockRequest.env_for("/users")))

      expect(request.path_params).to eq({})
    end

    it "exposes JSON body parameters without query, form, or path parameters" do
      rack_request = Rack::MockRequest.env_for(
        "/users/123?name=query",
        :method => "POST",
        :input => {name: "Ada", age: 37}.to_json,
        "CONTENT_TYPE" => "application/json"
      )
      rack_request["router.params"] = {"id" => "123"}
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.body_params).to eq(name: "Ada", age: 37)
    end

    it "returns an empty hash for body parameters when JSON body is not an object" do
      rack_request = Rack::MockRequest.env_for(
        "/users",
        :method => "POST",
        :input => ["Ada"].to_json,
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.body_params).to eq({})
    end

    it "marks JSON parse errors through body_params and keeps params empty" do
      rack_request = Rack::MockRequest.env_for(
        "/users?name=query",
        :method => "POST",
        :input => "{invalid json",
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.body_params).to eq({})
      expect(request.json_parse_error).to be(true)
      expect(request.params).to eq({})
    end

    it "exposes form parameters without query or path parameters" do
      rack_request = Rack::MockRequest.env_for(
        "/users/123?name=query&shared=query",
        :method => "POST",
        :params => {"name" => "form", "shared" => "form"},
        "CONTENT_TYPE" => "application/x-www-form-urlencoded"
      )
      rack_request["router.params"] = {"id" => "123", "shared" => "path"}
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.form_params).to eq(name: "form", shared: "form")
    end

    it "returns an empty hash for form parameters on JSON requests" do
      rack_request = Rack::MockRequest.env_for(
        "/users",
        :method => "POST",
        :input => {name: "Ada"}.to_json,
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.form_params).to eq({})
    end

    it "returns an empty hash for form parameters when there is no body or content type" do
      rack_request = Rack::MockRequest.env_for("/users?name=query")
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.form_params).to eq({})
    end

    # Param resolution skips the body sources when a request provably has none,
    # which it decides from the content type and the framing headers. A chunked
    # body has no Content-Length to read, so it must not be mistaken for absent.
    it "reads a chunked body that declares no content length" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
      end

      rack_request = Rack::MockRequest.env_for(
        "/users",
        :method => "POST",
        :input => {name: "Ada"}.to_json,
        "CONTENT_TYPE" => "application/json",
        "HTTP_TRANSFER_ENCODING" => "chunked"
      )
      rack_request.delete("CONTENT_LENGTH")
      request = Raxon::Request.new(Rack::Request.new(rack_request), endpoint)

      expect(request.params).to eq(name: "Ada")
    end

    # Same rule, reached the other way: no content type at all, so the framing
    # header is the only thing saying a body is coming.
    it "reads a chunked body that declares neither content type nor length" do
      rack_request = Rack::MockRequest.env_for(
        "/users",
        :method => "POST",
        :input => "name=Ada",
        "HTTP_TRANSFER_ENCODING" => "chunked"
      )
      rack_request.delete("CONTENT_TYPE")
      rack_request.delete("CONTENT_LENGTH")
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.params).to eq(name: "Ada")
    end

    it "preserves source-specific values when merged params have collisions" do
      rack_request = Rack::MockRequest.env_for(
        "/users/path?shared=query",
        :method => "POST",
        :input => {shared: "body"}.to_json,
        "CONTENT_TYPE" => "application/json"
      )
      rack_request["router.params"] = {"shared" => "path"}
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.query_params[:shared]).to eq("query")
      expect(request.body_params[:shared]).to eq("body")
      expect(request.path_params[:shared]).to eq("path")
      expect(request.params[:shared]).to eq("path")
    end

    it "does not consume the request body when body_params is read before params" do
      rack_request = Rack::MockRequest.env_for(
        "/users?source=query",
        :method => "POST",
        :input => {name: "Ada"}.to_json,
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_request))

      expect(request.body_params).to eq(name: "Ada")
      expect(request.params).to eq(source: "query", name: "Ada")
    end

    it "keeps source-specific params raw while merged params are validated and coerced" do
      schema = Dry::Schema.Params do
        required(:age).filled(:integer)
      end
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.instance_variable_set(:@request_schema, schema)
      rack_request = Rack::MockRequest.env_for("/users?age=37")
      request = Raxon::Request.new(Rack::Request.new(rack_request), endpoint)

      expect(request.query_params).to eq(age: "37")
      expect(request.params).to eq(age: 37)
    end
  end

  describe "#params" do
    it "returns query parameters" do
      rack_request = Rack::MockRequest.env_for("/test?foo=bar&baz=qux")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.params[:foo]).to eq("bar")
      expect(request.params[:baz]).to eq("qux")
    end

    it "caches params after first call" do
      rack_request = Rack::MockRequest.env_for("/test?foo=bar")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      first_result = request.params
      second_result = request.params

      expect(first_result.object_id).to eq(second_result.object_id)
    end

    it "merges JSON body params" do
      json_body = {name: "John", age: 30}.to_json
      rack_request = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.params[:name]).to eq("John")
      expect(request.params[:age]).to eq(30)
    end

    it "handles JSON parse errors" do
      rack_request = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => "{invalid json",
        "CONTENT_TYPE" => "application/json"
      )
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.params).to eq({})
      expect(request.json_parse_error).to be(true)
    end

    it "returns empty params early on JSON parse error" do
      rack_request = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => "{invalid json",
        "CONTENT_TYPE" => "application/json"
      )
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      # Call params twice to ensure early return path is tested
      request.params
      expect(request.params).to eq({})
    end

    it "merges router path parameters" do
      rack_request = Rack::MockRequest.env_for("/users/123")
      rack_request["router.params"] = {"id" => "123"}
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.params[:id]).to eq("123")
    end

    it "validates params with endpoint schema" do
      schema = Dry::Schema.Params do
        required(:name).filled(:string)
        required(:age).filled(:integer)
      end

      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.instance_variable_set(:@request_schema, schema)

      rack_request = Rack::MockRequest.env_for("/test?name=John&age=30")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req, endpoint)

      expect(request.params[:name]).to eq("John")
      expect(request.params[:age]).to eq(30)
      expect(request.validation_errors).to be_nil
    end

    it "captures validation errors with endpoint schema" do
      schema = Dry::Schema.Params do
        required(:name).filled(:string)
        required(:age).filled(:integer)
      end

      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.instance_variable_set(:@request_schema, schema)

      rack_request = Rack::MockRequest.env_for("/test?name=John")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req, endpoint)

      request.params
      expect(request.validation_errors).to have_key(:age)
    end
  end

  describe "#parse_json_body" do
    it "returns nil for non-JSON content type" do
      rack_request = Rack::MockRequest.env_for("/test", "CONTENT_TYPE" => "text/plain")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.parse_json_body).to be_nil
    end

    it "returns nil for empty body" do
      rack_request = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => "",
        "CONTENT_TYPE" => "application/json"
      )
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.parse_json_body).to be_nil
    end

    it "parses valid JSON body" do
      json_body = {foo: "bar"}.to_json
      rack_request = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      result = request.parse_json_body
      expect(result[:foo]).to eq("bar")
    end
  end

  describe "HTTP method delegation" do
    it "delegates #path" do
      rack_request = Rack::MockRequest.env_for("/test/path")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.path).to eq("/test/path")
    end

    it "delegates #fullpath" do
      rack_request = Rack::MockRequest.env_for("/test?foo=bar")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.fullpath).to eq("/test?foo=bar")
    end

    it "delegates #method" do
      rack_request = Rack::MockRequest.env_for("/test", method: "POST")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.method).to eq("POST")
    end

    it "delegates #get?" do
      rack_request = Rack::MockRequest.env_for("/test", method: "GET")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.get?).to be(true)
    end

    it "delegates #post?" do
      rack_request = Rack::MockRequest.env_for("/test", method: "POST")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.post?).to be(true)
    end

    it "delegates #put?" do
      rack_request = Rack::MockRequest.env_for("/test", method: "PUT")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.put?).to be(true)
    end

    it "delegates #patch?" do
      rack_request = Rack::MockRequest.env_for("/test", method: "PATCH")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.patch?).to be(true)
    end

    it "delegates #delete?" do
      rack_request = Rack::MockRequest.env_for("/test", method: "DELETE")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.delete?).to be(true)
    end
  end

  describe "#headers" do
    it "returns HTTP headers" do
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_AUTHORIZATION" => "Bearer token")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.headers).to have_key("HTTP_AUTHORIZATION")
      expect(request.headers["HTTP_AUTHORIZATION"]).to eq("Bearer token")
    end
  end

  describe "#headers_hash" do
    it "returns normalized headers" do
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_AUTHORIZATION" => "Bearer token")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.headers_hash).to have_key("Authorization")
      expect(request.headers_hash["Authorization"]).to eq("Bearer token")
    end

    it "normalizes custom headers with underscores" do
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_X_CUSTOM_HEADER" => "value")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.headers_hash).to have_key("X-Custom-Header")
      expect(request.headers_hash["X-Custom-Header"]).to eq("value")
    end

    it "handles multiple headers" do
      rack_request = Rack::MockRequest.env_for(
        "/test",
        "HTTP_AUTHORIZATION" => "Bearer token",
        "HTTP_CONTENT_TYPE" => "application/json",
        "HTTP_X_REQUEST_ID" => "123456"
      )
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      headers = request.headers_hash
      expect(headers["Authorization"]).to eq("Bearer token")
      expect(headers["Content-Type"]).to eq("application/json")
      expect(headers["X-Request-Id"]).to eq("123456")
    end

    it "returns empty hash when no HTTP headers present" do
      rack_request = Rack::MockRequest.env_for("/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.headers_hash).to eq({})
    end
  end

  describe "#header" do
    it "returns specific header value" do
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_X_CUSTOM" => "value")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.header("HTTP_X_CUSTOM")).to eq("value")
    end
  end

  describe "#content_type" do
    it "returns content type" do
      rack_request = Rack::MockRequest.env_for("/test", "CONTENT_TYPE" => "application/json")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.content_type).to eq("application/json")
    end
  end

  describe "#json?" do
    it "returns true for application/json" do
      rack_request = Rack::MockRequest.env_for("/test", "CONTENT_TYPE" => "application/json")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.json?).to be(true)
    end

    it "returns false for other content types" do
      rack_request = Rack::MockRequest.env_for("/test", "CONTENT_TYPE" => "text/html")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.json?).to be(false)
    end

    it "returns false when content_type is nil" do
      rack_request = Rack::MockRequest.env_for("/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      # json? uses safe navigation, so nil&.include? returns nil, not false
      expect(request.json?).to be_falsey
    end
  end

  describe "#body" do
    it "returns request body" do
      rack_request = Rack::MockRequest.env_for("/test", method: "POST", input: "test body")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.body).to be_a(StringIO)
    end
  end

  describe "#body_string" do
    it "reads body as string" do
      rack_request = Rack::MockRequest.env_for("/test", method: "POST", input: "test body")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.body_string).to eq("test body")
    end

    it "rewinds body after reading" do
      rack_request = Rack::MockRequest.env_for("/test", method: "POST", input: "test body")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      request.body_string
      expect(request.body_string).to eq("test body")
    end
  end

  describe "#json" do
    it "parses JSON body" do
      json_body = {foo: "bar"}.to_json
      rack_request = Rack::MockRequest.env_for("/test", method: "POST", input: json_body)
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.json["foo"]).to eq("bar")
    end

    it "returns nil for invalid JSON" do
      rack_request = Rack::MockRequest.env_for("/test", method: "POST", input: "{invalid")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.json).to be_nil
    end
  end

  describe "#cookies" do
    it "returns cookies" do
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_COOKIE" => "session=abc123")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.cookies).to have_key("session")
    end
  end

  describe "#scheme" do
    it "returns request scheme" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.scheme).to eq("http")
    end
  end

  describe "#ssl?" do
    it "returns false for http" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.ssl?).to be(false)
    end

    it "returns true for https" do
      rack_request = Rack::MockRequest.env_for("https://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.ssl?).to be(true)
    end
  end

  describe "#host_with_port" do
    it "returns host with port" do
      rack_request = Rack::MockRequest.env_for("http://example.com:8080/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.host_with_port).to eq("example.com:8080")
    end
  end

  describe "#base_url" do
    it "returns base URL" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.base_url).to eq("http://example.com")
    end
  end

  describe "#url" do
    it "returns full URL" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test?foo=bar")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.url).to eq("http://example.com/test?foo=bar")
    end
  end

  describe "#ip" do
    it "returns client IP" do
      rack_request = Rack::MockRequest.env_for("/test", "REMOTE_ADDR" => "192.168.1.1")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.ip).to eq("192.168.1.1")
    end
  end

  describe "#remote_ip" do
    def request_with(remote_addr:, forwarded_for: nil)
      env = {"REMOTE_ADDR" => remote_addr}
      env["HTTP_X_FORWARDED_FOR"] = forwarded_for if forwarded_for
      Raxon::Request.new(Rack::Request.new(Rack::MockRequest.env_for("/test", env)))
    end

    context "with no trusted proxies configured (default)" do
      it "ignores forgeable X-Forwarded-For and returns the connection peer" do
        request = request_with(remote_addr: "192.168.1.1", forwarded_for: "203.0.113.1")

        expect(request.remote_ip).to eq("192.168.1.1")
      end
    end

    context "with trusted proxies configured" do
      # spec_helper resets configuration in a before hook, so set this after it.
      before { Raxon.configuration.trusted_proxies = ["10.0.0.0/8"] }

      it "returns the client when the peer is a trusted proxy" do
        request = request_with(remote_addr: "10.0.0.5", forwarded_for: "203.0.113.1")

        expect(request.remote_ip).to eq("203.0.113.1")
      end

      it "walks from the right, skipping every trusted hop" do
        request = request_with(remote_addr: "10.0.0.9", forwarded_for: "203.0.113.1, 10.0.0.1, 10.0.0.2")

        expect(request.remote_ip).to eq("203.0.113.1")
      end

      it "ignores a forged leftmost entry once a real client sits to its right" do
        # An attacker prepends 9.9.9.9; the trusted proxy appended the real
        # client 203.0.113.1, which is untrusted and to the right, so it wins.
        request = request_with(remote_addr: "10.0.0.9", forwarded_for: "9.9.9.9, 203.0.113.1")

        expect(request.remote_ip).to eq("203.0.113.1")
      end

      it "returns the peer when it is not a trusted proxy (direct connection)" do
        # Backend reached directly; the whole X-Forwarded-For is attacker-supplied.
        request = request_with(remote_addr: "203.0.113.7", forwarded_for: "9.9.9.9")

        expect(request.remote_ip).to eq("203.0.113.7")
      end

      it "returns the peer when there is no X-Forwarded-For" do
        request = request_with(remote_addr: "10.0.0.9")

        expect(request.remote_ip).to eq("10.0.0.9")
      end

      it "supports plain-IP (non-CIDR) trusted entries" do
        Raxon.configuration.trusted_proxies = ["127.0.0.1"]
        request = request_with(remote_addr: "127.0.0.1", forwarded_for: "203.0.113.1")

        expect(request.remote_ip).to eq("203.0.113.1")
      end

      it "accepts IPAddr objects as trusted entries" do
        Raxon.configuration.trusted_proxies = [IPAddr.new("10.0.0.0/8")]
        request = request_with(remote_addr: "10.0.0.9", forwarded_for: "203.0.113.1")

        expect(request.remote_ip).to eq("203.0.113.1")
      end
    end

    context "with a malformed trusted-proxy entry" do
      it "ignores the bad entry rather than widening trust or crashing" do
        Raxon.configuration.trusted_proxies = ["not-an-ip", "10.0.0.0/8"]
        request = request_with(remote_addr: "10.0.0.9", forwarded_for: "203.0.113.1")

        expect(request.remote_ip).to eq("203.0.113.1")
      end
    end

    context "with a malformed entry in the forwarding chain" do
      it "treats an unparseable address as untrusted and stops the walk there" do
        Raxon.configuration.trusted_proxies = ["10.0.0.0/8"]
        request = request_with(remote_addr: "10.0.0.9", forwarded_for: "203.0.113.1, garbage")

        expect(request.remote_ip).to eq("garbage")
      end
    end
  end

  describe "#user_agent" do
    it "returns user agent" do
      rack_request = Rack::MockRequest.env_for("/test", "HTTP_USER_AGENT" => "TestAgent/1.0")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.user_agent).to eq("TestAgent/1.0")
    end
  end

  describe "#env" do
    it "returns Rack environment" do
      rack_request = Rack::MockRequest.env_for("/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.env).to be_a(Hash)
      expect(request.env).to have_key("REQUEST_METHOD")
    end
  end

  describe "#domain" do
    it "extracts domain from simple hostname" do
      rack_request = Rack::MockRequest.env_for("http://www.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to eq("example.com")
    end

    it "extracts domain with multiple subdomains" do
      rack_request = Rack::MockRequest.env_for("http://dev.www.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to eq("example.com")
    end

    it "handles multi-part TLDs with tld_length parameter" do
      rack_request = Rack::MockRequest.env_for("http://www.example.co.uk/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain(2)).to eq("example.co.uk")
    end

    it "returns nil for IP addresses" do
      rack_request = Rack::MockRequest.env_for("http://192.168.1.1/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to be_nil
    end

    it "returns nil for IPv6 addresses" do
      rack_request = Rack::MockRequest.env_for("http://[2001:db8::1]/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to be_nil
    end

    it "returns nil when host is too short for tld_length" do
      rack_request = Rack::MockRequest.env_for("http://localhost/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to be_nil
    end

    it "returns nil for empty host" do
      rack_request = Rack::MockRequest.env_for("/test")
      rack_req = Rack::Request.new(rack_request)
      allow(rack_req).to receive(:host).and_return("")

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to be_nil
    end

    it "handles domain without subdomains" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.domain).to eq("example.com")
    end
  end

  describe "#subdomain" do
    it "returns empty string when no subdomains" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomain).to eq("")
    end

    it "returns single subdomain" do
      rack_request = Rack::MockRequest.env_for("http://www.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomain).to eq("www")
    end

    it "returns multiple subdomains joined with dots" do
      rack_request = Rack::MockRequest.env_for("http://dev.www.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomain).to eq("dev.www")
    end

    it "handles multi-part TLDs with tld_length parameter" do
      rack_request = Rack::MockRequest.env_for("http://dev.www.example.co.uk/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomain(2)).to eq("dev.www")
    end

    it "adjusts subdomain extraction based on tld_length" do
      rack_request = Rack::MockRequest.env_for("http://www.example.co.uk/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      # With tld_length=1, treats "uk" as TLD, so "example.co" is domain and "www" is subdomain
      expect(request.subdomain(1)).to eq("www.example")

      # With tld_length=2, treats "co.uk" as TLD, so "example.co.uk" is domain and "www" is subdomain
      expect(request.subdomain(2)).to eq("www")
    end

    it "returns empty string for IP addresses" do
      rack_request = Rack::MockRequest.env_for("http://192.168.1.1/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomain).to eq("")
    end
  end

  describe "#subdomains" do
    it "returns empty array when no subdomains" do
      rack_request = Rack::MockRequest.env_for("http://example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq([])
    end

    it "returns array with single subdomain" do
      rack_request = Rack::MockRequest.env_for("http://www.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq(["www"])
    end

    it "returns array with multiple subdomains" do
      rack_request = Rack::MockRequest.env_for("http://dev.www.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq(["dev", "www"])
    end

    it "handles multi-part TLDs with tld_length parameter" do
      rack_request = Rack::MockRequest.env_for("http://dev.www.example.co.uk/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains(2)).to eq(["dev", "www"])
    end

    it "adjusts subdomain extraction based on tld_length" do
      rack_request = Rack::MockRequest.env_for("http://api.staging.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      # Default tld_length=1
      expect(request.subdomains).to eq(["api", "staging"])

      # With tld_length=2, "example.com" is treated as TLD
      expect(request.subdomains(2)).to eq(["api"])
    end

    it "returns empty array for IP addresses" do
      rack_request = Rack::MockRequest.env_for("http://192.168.1.1/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq([])
    end

    it "returns empty array for IPv6 addresses" do
      rack_request = Rack::MockRequest.env_for("http://[2001:db8::1]/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq([])
    end

    it "returns empty array when host too short" do
      rack_request = Rack::MockRequest.env_for("http://localhost/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq([])
    end

    it "handles deeply nested subdomains" do
      rack_request = Rack::MockRequest.env_for("http://a.b.c.d.example.com/test")
      rack_req = Rack::Request.new(rack_request)

      request = Raxon::Request.new(rack_req)

      expect(request.subdomains).to eq(["a", "b", "c", "d"])
    end
  end
end

RSpec.describe Raxon::Request, "host and body edge cases" do
  it "returns no subdomains for an empty host" do
    rack_req = Rack::Request.new(Rack::MockRequest.env_for("/test"))
    allow(rack_req).to receive(:host).and_return("")

    request = Raxon::Request.new(rack_req)

    expect(request.subdomains).to eq([])
  end

  it "memoizes form params so the body is only parsed once" do
    env = Rack::MockRequest.env_for(
      "/users",
      :method => "POST",
      :input => "name=Jane",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded"
    )
    request = Raxon::Request.new(Rack::Request.new(env))

    first = request.form_params

    expect(first).to eq(name: "Jane")
    expect(request.form_params).to equal(first)
  end
end

RSpec.describe Raxon::Request, "body handling without an input stream" do
  it "returns an empty body string when the env has no rack.input" do
    env = Rack::MockRequest.env_for("/test")
    env.delete("rack.input")
    request = Raxon::Request.new(Rack::Request.new(env))

    expect(request.body_string).to eq("")
  end
end
