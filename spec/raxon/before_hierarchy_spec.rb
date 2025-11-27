require "spec_helper"

RSpec.describe "Before block execution hierarchy" do
  before do
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
  end

  describe "before blocks execute in parent-to-child order" do
    it "executes parent before block, then child before block, then handler" do
      execution_order = []

      # Register parent route with only a before block
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent auth filter"
        endpoint.before do |request, response|
          execution_order << :parent_before
          response.rack_response["X-Auth"] = "parent"
        end
      end

      # Register child route with before block and handler
      Raxon::RouteLoader.register("routes/api/v1/statistics/get.rb") do |endpoint|
        endpoint.description "Get statistics"
        endpoint.response 200, type: :object do |response|
          response.property :data, type: :string
        end
        endpoint.before do |request, response|
          execution_order << :child_before
          response.rack_response["X-Stats"] = "child"
        end
        endpoint.handler do |request, response|
          execution_order << :handler
          response.code = :ok
          response.body = {data: "stats"}
        end
      end

      # Find the route and verify hierarchy
      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/statistics")
      expect(route_data).not_to be_nil
      expect(route_data[:endpoints].length).to eq(2)

      # Execute the request through router to trigger before block execution
      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/statistics", method: "GET")
      status, headers, body = router.call(env)

      # Verify execution order
      expect(execution_order).to eq([:parent_before, :child_before, :handler])

      # Verify response
      expect(status).to eq(200)
      expect(headers["X-Auth"]).to eq("parent")
      expect(headers["X-Stats"]).to eq("child")
      expect(JSON.parse(body.first)).to eq({"data" => "stats"})
    end

    it "executes only parent before block if there is no child before block" do
      execution_order = []

      # Register parent route with before block
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent filter"
        endpoint.before do |request, response|
          execution_order << :parent_before
          response.rack_response["X-Parent"] = "executed"
        end
      end

      # Register child route with only handler (no before block)
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.description "Get users"
        endpoint.response 200, type: :array do |response|
          response.property :id, type: :string
        end
        endpoint.handler do |request, response|
          execution_order << :handler
          response.code = :ok
          response.body = {id: "1"}
        end
      end

      # Execute the request through router
      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
      status, headers, _body = router.call(env)

      # Only parent before and handler should execute
      expect(execution_order).to eq([:parent_before, :handler])
      expect(status).to eq(200)
      expect(headers["X-Parent"]).to eq("executed")
    end

    it "handles multiple levels of nesting" do
      execution_order = []

      # Level 1: /api
      Raxon::RouteLoader.register("routes/api/get.rb") do |endpoint|
        endpoint.before do |request, response|
          execution_order << :level_1_before
          response.rack_response["X-Level-1"] = "yes"
        end
      end

      # Level 2: /api/v1
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.before do |request, response|
          execution_order << :level_2_before
          response.rack_response["X-Level-2"] = "yes"
        end
      end

      # Level 3: /api/v1/users
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.response 200, type: :array
        endpoint.before do |request, response|
          execution_order << :level_3_before
          response.rack_response["X-Level-3"] = "yes"
        end
        endpoint.handler do |request, response|
          execution_order << :handler
          response.code = :ok
          response.body = []
        end
      end

      # Execute the request through router
      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
      status, headers, _ = router.call(env)

      # Verify execution order: parent to child
      expect(execution_order).to eq([:level_1_before, :level_2_before, :level_3_before, :handler])
      expect(status).to eq(200)
      expect(headers["X-Level-1"]).to eq("yes")
      expect(headers["X-Level-2"]).to eq("yes")
      expect(headers["X-Level-3"]).to eq("yes")
    end
  end

  describe "routes with only before blocks (no handler)" do
    it "allows endpoints without handlers" do
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Auth filter only"
        endpoint.before do |request, response|
          response.rack_response["X-Auth"] = "ok"
        end
      end

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1")
      endpoint = route_data[:endpoint]

      expect(endpoint.has_before?).to be true
      expect(endpoint.has_handler?).to be false
    end

    it "displays correctly in routes collection" do
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent auth"
        endpoint.before { |request, response| }
      end

      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.description "Get users"
        endpoint.response 200, type: :array
        endpoint.handler { |request, response|
          response.code = :ok
          response.body = []
        }
      end

      routes = Raxon::RouteLoader.routes
      all_routes = routes.all

      expect(all_routes.length).to eq(2)

      # Check parent route
      parent_route = all_routes.find { |key, _| key[:path] == "/api/v1" }&.last
      expect(parent_route[:endpoint].has_before?).to be true
      expect(parent_route[:endpoint].has_handler?).to be false

      # Check child route
      child_route = all_routes.find { |key, _| key[:path] == "/api/v1/users" }&.last
      expect(child_route[:endpoint].has_before?).to be false
      expect(child_route[:endpoint].has_handler?).to be true
    end
  end
end
