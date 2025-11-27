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
end
