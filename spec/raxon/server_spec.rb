require "spec_helper"

RSpec.describe Raxon::Server, load_routes: true do
  describe "#initialize" do
    it "creates a server with a routes directory" do
      server = Raxon::Server.new

      expect(server.router).to be_a(Raxon::Router)
    end

    it "allows middleware configuration via block" do
      middleware_added = false

      Raxon::Server.new do |_app|
        middleware_added = true
      end

      expect(middleware_added).to be true
    end

    it "honors a routes_directory: keyword by setting the configuration" do
      Raxon::Server.new(routes_directory: "custom/routes")

      expect(Raxon.configuration.routes_directory).to eq("custom/routes")
    end

    it "raises on an unknown keyword rather than silently ignoring it" do
      expect { Raxon::Server.new(routez_directory: "typo") }
        .to raise_error(ArgumentError, /unknown keyword: routez_directory/)
    end

    it "lists every unknown keyword when several are given" do
      expect { Raxon::Server.new(foo: 1, bar: 2) }
        .to raise_error(ArgumentError, /unknown keywords: foo, bar/)
    end

    it "delegates unmatched routes to a fallback: keyword app" do
      fallback = ->(_env) { [299, {"content-type" => "text/plain"}, ["from-fallback"]] }
      server = Raxon::Server.new(fallback: fallback)

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      status, _headers, body = server.call(env)

      expect(status).to eq(299)
      expect(body.first).to eq("from-fallback")
    end
  end

  describe "#call" do
    it "handles requests through the router" do
      server = Raxon::Server.new

      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      status, headers, body = server.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(body.first).to include("test")
    end

    it "returns 404 for unregistered routes" do
      server = Raxon::Server.new

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      status, headers, body = server.call(env)

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("application/json")
      expect(body.first).to include("Not Found")
    end
  end

  describe "automatic error handling" do
    # /api/v1/error is a fixture route whose handler raises StandardError.
    it "returns a JSON 500 for an unhandled exception by default" do
      server = Raxon::Server.new

      status, headers, body = server.call(Rack::MockRequest.env_for("/api/v1/error"))

      expect(status).to eq(500)
      expect(headers["content-type"]).to eq("application/json")
      expect(JSON.parse(body.first)).to eq("error" => "Internal Server Error")
    end

    it "lets the exception propagate when wrap_error_handler is disabled" do
      Raxon.configuration.wrap_error_handler = false
      server = Raxon::Server.new

      expect { server.call(Rack::MockRequest.env_for("/api/v1/error")) }
        .to raise_error(StandardError, /intentional error/)
    end

    it "does not auto-wrap when an ErrorHandler was added explicitly" do
      server = Raxon::Server.new { |s| s.use Raxon::ErrorHandler }

      expect(server.send(:auto_wrap_error_handler?)).to be(false)
    end
  end
end
