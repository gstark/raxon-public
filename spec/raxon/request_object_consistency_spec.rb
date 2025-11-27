require "spec_helper"

RSpec.describe "Single request object per request lifecycle" do
  before do
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
  end

  describe "single request object in single endpoint" do
    it "passes the same Raxon::Request object instance to before and handler" do
      request_objects = []

      Raxon::RouteLoader.register("routes/api/v1/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object
        endpoint.before do |request, _response|
          request_objects << request.object_id
        end
        endpoint.handler do |request, _response|
          request_objects << request.object_id
        end
      end

      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      router.call(env)

      # Should have recorded object IDs from before and handler
      expect(request_objects.length).to eq(2)
      # Both should be the same object
      expect(request_objects.first).to eq(request_objects.last)
    end
  end

  describe "single request object in route hierarchy" do
    it "passes the same Raxon::Request object to all before blocks and handler" do
      request_objects = []

      # Register parent route with before block
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.before do |request, _response|
          request_objects << request.object_id
        end
      end

      # Register child route with before block and handler
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.response 200, type: :array
        endpoint.before do |request, _response|
          request_objects << request.object_id
        end
        endpoint.handler do |request, _response|
          request_objects << request.object_id
        end
      end

      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
      router.call(env)

      # Should have 3 entries: parent before, child before, handler
      expect(request_objects.length).to eq(3)
      # All should be the same object
      expect(request_objects.uniq.length).to eq(1)
    end

    it "passes the same Raxon::Request object across multiple hierarchy levels" do
      request_objects = []

      # Level 1: /api
      Raxon::RouteLoader.register("routes/api/get.rb") do |endpoint|
        endpoint.before do |request, _response|
          request_objects << request.object_id
        end
      end

      # Level 2: /api/v1
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.before do |request, _response|
          request_objects << request.object_id
        end
      end

      # Level 3: /api/v1/users
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.response 200, type: :array
        endpoint.before do |request, _response|
          request_objects << request.object_id
        end
        endpoint.handler do |request, _response|
          request_objects << request.object_id
        end
      end

      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
      router.call(env)

      # Should have 4 entries: 3 before blocks + 1 handler
      expect(request_objects.length).to eq(4)
      # All should be the same object
      expect(request_objects.uniq.length).to eq(1)
    end

    it "allows request state modification in before block to be accessible in handler" do
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.before do |request, _response|
          request.instance_variable_set(:@custom_state, "parent_value")
        end
      end

      Raxon::RouteLoader.register("routes/api/v1/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object
        endpoint.before do |request, _response|
          request.instance_variable_set(:@child_state, "child_value")
        end
        endpoint.handler do |request, response|
          # Access state set in both before blocks
          parent_state = request.instance_variable_get(:@custom_state)
          child_state = request.instance_variable_get(:@child_state)
          response.code = :ok
          response.body = {parent: parent_state, child: child_state}
        end
      end

      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      _status, _headers, body = router.call(env)

      result = JSON.parse(body.first)
      expect(result["parent"]).to eq("parent_value")
      expect(result["child"]).to eq("child_value")
    end
  end
end
