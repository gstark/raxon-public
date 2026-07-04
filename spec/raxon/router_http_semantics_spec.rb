# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Routes, "#allowed_methods" do
  let(:routes) { described_class.new }
  let(:endpoint) { Raxon::OpenApi::Endpoint.new }

  it "returns the registered methods plus HEAD and OPTIONS for a GET route" do
    routes.register("GET", "/users", endpoint)

    expect(routes.allowed_methods("/users")).to eq(%w[GET HEAD OPTIONS])
  end

  it "does not add HEAD when no GET route exists" do
    routes.register("POST", "/users", endpoint)

    expect(routes.allowed_methods("/users")).to eq(%w[POST OPTIONS])
  end

  it "returns all supported methods for an ALL route" do
    routes.register("ALL", "/users", endpoint)

    expect(routes.allowed_methods("/users")).to eq(Raxon::Routes::SUPPORTED_METHODS)
  end

  it "returns an empty array for an unknown path" do
    routes.register("GET", "/users", endpoint)

    expect(routes.allowed_methods("/posts")).to eq([])
  end

  it "matches dynamic paths" do
    routes.register("PUT", "/users/{id}", endpoint)

    expect(routes.allowed_methods("/users/42")).to eq(%w[PUT OPTIONS])
  end

  it "unions methods across exact and dynamic entries in canonical order" do
    exact_endpoint = Raxon::OpenApi::Endpoint.new
    routes.register("POST", "/users/me", exact_endpoint)
    routes.register("GET", "/users/{id}", endpoint)

    expect(routes.allowed_methods("/users/me")).to eq(%w[GET HEAD POST OPTIONS])
  end

  it "does not scan a dynamic entry twice when it is also the exact match" do
    routes.register("GET", "/users/{id}", endpoint)

    expect(routes.allowed_methods("/users/{id}")).to eq(%w[GET HEAD OPTIONS])
  end
end

RSpec.describe Raxon::Routes, "HEAD fallback to GET" do
  let(:routes) { described_class.new }
  let(:get_endpoint) { Raxon::OpenApi::Endpoint.new }

  it "serves HEAD from the GET route and marks it head_from_get" do
    routes.register("GET", "/users", get_endpoint)

    result = routes.find("HEAD", "/users")

    expect(result[:endpoint]).to eq(get_endpoint)
    expect(result[:head_from_get]).to be(true)
  end

  it "prefers an explicit HEAD route" do
    head_endpoint = Raxon::OpenApi::Endpoint.new
    routes.register("GET", "/users", get_endpoint)
    routes.register("HEAD", "/users", head_endpoint)

    result = routes.find("HEAD", "/users")

    expect(result[:endpoint]).to eq(head_endpoint)
    expect(result[:head_from_get]).to be_nil
  end

  it "prefers an ALL route over the GET fallback" do
    all_endpoint = Raxon::OpenApi::Endpoint.new
    routes.register("GET", "/users", get_endpoint)
    routes.register("ALL", "/users", all_endpoint)

    result = routes.find("HEAD", "/users")

    expect(result[:endpoint]).to eq(all_endpoint)
    expect(result[:head_from_get]).to be_nil
  end

  it "serves HEAD from a dynamic GET route with params extracted" do
    routes.register("GET", "/users/{id}", get_endpoint)

    result = routes.find("HEAD", "/users/42")

    expect(result[:endpoint]).to eq(get_endpoint)
    expect(result[:head_from_get]).to be(true)
    expect(result[:params]).to eq({id: "42"})
  end

  it "skips non-matching dynamic entries when falling back" do
    other_endpoint = Raxon::OpenApi::Endpoint.new
    routes.register("GET", "/posts/{id}", other_endpoint)
    routes.register("GET", "/users/{id}", get_endpoint)

    result = routes.find("HEAD", "/users/42")

    expect(result[:endpoint]).to eq(get_endpoint)
  end

  it "does not fall back for a dynamic entry without a GET route" do
    routes.register("POST", "/users/{id}", get_endpoint)

    expect(routes.find("HEAD", "/users/42")).to be_nil
  end

  it "does not fall back for non-HEAD methods" do
    routes.register("GET", "/users", get_endpoint)

    expect(routes.find("POST", "/users")).to be_nil
  end
end

RSpec.describe Raxon::Router, "route auto-loading" do
  it "loads routes from the configured directory on initialization" do
    Raxon.configure do |config|
      config.routes_directory = File.join(__dir__, "..", "fixtures", "routes")
    end

    router = Raxon::Router.new

    env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
    status, = router.call(env)

    expect(status).to eq(200)
  end

  it "does not disturb routes defined programmatically beforehand" do
    define_route("routes/manual/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| response.ok source: "manual" }
    end

    router = Raxon::Router.new

    env = Rack::MockRequest.env_for("/manual", method: "GET")
    status, _, body = router.call(env)

    expect(status).to eq(200)
    expect(JSON.parse(body.first)).to eq({"source" => "manual"})
  end

  it "is a no-op when the routes directory does not exist" do
    Raxon.configure { |config| config.routes_directory = "does/not/exist" }

    expect { Raxon::Router.new }.not_to raise_error
  end
end

RSpec.describe Raxon::Router, "HTTP semantics" do
  let(:router) { Raxon::Router.new }

  def call(method, path, headers = {})
    env = Rack::MockRequest.env_for(path, {method: method}.merge(headers))
    router.call(env)
  end

  describe "automatic HEAD from GET" do
    before do
      define_route("routes/things/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.header "X-Handler", "get"
          response.ok things: []
        end
      end
    end

    it "runs the GET handler and strips the body" do
      status, headers, body = call("HEAD", "/things")

      expect(status).to eq(200)
      expect(headers["X-Handler"]).to eq("get")
      expect(body).to eq([])
    end

    it "still returns the full body for GET" do
      status, _, body = call("GET", "/things")

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq({"things" => []})
    end

    it "prefers an explicit HEAD route" do
      define_route("routes/things/head.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.header "X-Handler", "head"
          response.no_content
        end
      end

      status, headers, = call("HEAD", "/things")

      expect(status).to eq(204)
      expect(headers["X-Handler"]).to eq("head")
    end

    it "closes a closeable body when stripping it" do
      closeable = Class.new {
        attr_reader :closed

        def close
          @closed = true
        end
      }.new

      stripped = router.send(:strip_head_body, [200, {"content-type" => "application/json"}, closeable])

      expect(closeable.closed).to be(true)
      expect(stripped).to eq([200, {"content-type" => "application/json"}, []])
    end

    it "strips a streamed body" do
      define_route("routes/streams/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.write "streamed"
        end
      end

      status, _, body = call("HEAD", "/streams")

      expect(status).to eq(200)
      expect(body).to eq([])
    end

    it "extracts path params for dynamic routes" do
      define_route("routes/things/__id__/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.header "X-Id", request.path_params[:id]
          response.ok id: request.path_params[:id]
        end
      end

      status, headers, body = call("HEAD", "/things/42")

      expect(status).to eq(200)
      expect(headers["X-Id"]).to eq("42")
      expect(body).to eq([])
    end
  end

  describe "405 Method Not Allowed" do
    before do
      define_route("routes/things/get.rb") do |endpoint|
        endpoint.handler { |request, response, metadata| response.ok }
      end
    end

    it "returns 405 with an Allow header when the path exists but the method does not" do
      status, headers, body = call("POST", "/things")

      expect(status).to eq(405)
      expect(headers["allow"]).to eq("GET, HEAD, OPTIONS")
      expect(headers["content-type"]).to eq("application/json")
      expect(JSON.parse(body.first)).to eq({"error" => "Method Not Allowed"})
    end

    it "returns 404 for a path that matches no route" do
      status, headers, = call("POST", "/nowhere")

      expect(status).to eq(404)
      expect(headers).not_to have_key("allow")
    end

    it "delegates to the fallback app instead of returning 405" do
      fallback = ->(env) { [201, {"content-type" => "text/plain"}, ["fallback"]] }
      router = Raxon::Router.new(fallback: fallback)

      env = Rack::MockRequest.env_for("/things", method: "POST")
      status, _, body = router.call(env)

      expect(status).to eq(201)
      expect(body).to eq(["fallback"])
    end

    it "uses the catchall endpoint instead of returning 405" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok source: "catchall"
        end
      end

      status, _, body = call("POST", "/things")

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq({"source" => "catchall"})
    end
  end

  describe "automatic OPTIONS" do
    before do
      define_route("routes/things/get.rb") do |endpoint|
        endpoint.handler { |request, response, metadata| response.ok }
      end
      define_route("routes/things/post.rb") do |endpoint|
        endpoint.handler { |request, response, metadata| response.created }
      end
    end

    it "answers OPTIONS with 204 and the Allow header" do
      status, headers, body = call("OPTIONS", "/things")

      expect(status).to eq(204)
      expect(headers["allow"]).to eq("GET, HEAD, POST, OPTIONS")
      expect(body).to eq([])
    end

    it "prefers an explicit OPTIONS route" do
      define_route("routes/things/options.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.header "allow", "GET"
          response.no_content
        end
      end

      _, headers, = call("OPTIONS", "/things")

      expect(headers["allow"]).to eq("GET")
    end

    it "returns 404 for OPTIONS on an unknown path" do
      status, = call("OPTIONS", "/nowhere")

      expect(status).to eq(404)
    end
  end

  describe "configurable 404 handler" do
    it "uses the configured not_found handler" do
      Raxon.configure do |config|
        config.not_found do |request, response|
          response.body = {error: "no such endpoint", path: request.rack_request.path}
        end
      end

      status, headers, body = call("GET", "/nowhere")

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("application/json")
      expect(JSON.parse(body.first)).to eq({"error" => "no such endpoint", "path" => "/nowhere"})
    end

    it "lets the handler change the status code" do
      Raxon.configure do |config|
        config.not_found do |request, response|
          response.code = :gone
          response.body = {error: "gone"}
        end
      end

      status, = call("GET", "/nowhere")

      expect(status).to eq(410)
    end

    it "supports halt inside the handler" do
      Raxon.configure do |config|
        config.not_found do |request, response|
          response.halt code: :service_unavailable, body: {error: "down"}
        end
      end

      status, _, body = call("GET", "/nowhere")

      expect(status).to eq(503)
      expect(JSON.parse(body.first)).to eq({"error" => "down"})
    end

    it "returns the default 404 when no handler is configured" do
      status, _, body = call("GET", "/nowhere")

      expect(status).to eq(404)
      expect(JSON.parse(body.first)).to eq({"error" => "Not Found"})
    end

    it "ignores a not_found call without a block" do
      Raxon.configure do |config|
        config.not_found
      end

      expect(Raxon.configuration.not_found_handler).to be_nil
    end
  end
end
