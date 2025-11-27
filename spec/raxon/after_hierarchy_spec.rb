require "spec_helper"

RSpec.describe "After block execution hierarchy" do
  before do
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
  end

  describe "after blocks execute in child-to-parent order" do
    it "executes handler, then child after block, then parent after block" do
      execution_order = []

      # Register parent route with only an after block
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent logging filter"
        endpoint.after do |request, response|
          execution_order << :parent_after
          response.rack_response["X-Parent-After"] = "executed"
        end
      end

      # Register child route with after block and handler
      Raxon::RouteLoader.register("routes/api/v1/statistics/get.rb") do |endpoint|
        endpoint.description "Get statistics"
        endpoint.response 200, type: :object do |response|
          response.property :data, type: :string
        end
        endpoint.after do |request, response|
          execution_order << :child_after
          response.rack_response["X-Child-After"] = "executed"
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

      # Execute the request through router to trigger after block execution
      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/statistics", method: "GET")
      status, headers, body = router.call(env)

      # Verify execution order: handler first, then child after, then parent after
      expect(execution_order).to eq([:handler, :child_after, :parent_after])

      # Verify response
      expect(status).to eq(200)
      expect(headers["X-Parent-After"]).to eq("executed")
      expect(headers["X-Child-After"]).to eq("executed")
      expect(JSON.parse(body.first)).to eq({"data" => "stats"})
    end

    it "executes only parent after block if there is no child after block" do
      execution_order = []

      # Register parent route with after block
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent filter"
        endpoint.after do |request, response|
          execution_order << :parent_after
          response.rack_response["X-Parent"] = "executed"
        end
      end

      # Register child route with only handler (no after block)
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

      # Handler first, then parent after
      expect(execution_order).to eq([:handler, :parent_after])
      expect(status).to eq(200)
      expect(headers["X-Parent"]).to eq("executed")
    end

    it "handles multiple levels of nesting" do
      execution_order = []

      # Level 1: /api
      Raxon::RouteLoader.register("routes/api/get.rb") do |endpoint|
        endpoint.after do |request, response|
          execution_order << :level_1_after
          response.rack_response["X-Level-1"] = "yes"
        end
      end

      # Level 2: /api/v1
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.after do |request, response|
          execution_order << :level_2_after
          response.rack_response["X-Level-2"] = "yes"
        end
      end

      # Level 3: /api/v1/users
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.response 200, type: :array
        endpoint.after do |request, response|
          execution_order << :level_3_after
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

      # Verify execution order: handler first, then child to parent after blocks
      expect(execution_order).to eq([:handler, :level_3_after, :level_2_after, :level_1_after])
      expect(status).to eq(200)
      expect(headers["X-Level-1"]).to eq("yes")
      expect(headers["X-Level-2"]).to eq("yes")
      expect(headers["X-Level-3"]).to eq("yes")
    end
  end

  describe "routes with only after blocks (no handler)" do
    it "allows endpoints without handlers" do
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Logging filter only"
        endpoint.after do |request, response|
          response.rack_response["X-Log"] = "ok"
        end
      end

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1")
      endpoint = route_data[:endpoint]

      expect(endpoint.has_after?).to be true
      expect(endpoint.has_handler?).to be false
    end

    it "displays correctly in routes collection" do
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent logging"
        endpoint.after { |request, response| }
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
      expect(parent_route[:endpoint].has_after?).to be true
      expect(parent_route[:endpoint].has_handler?).to be false

      # Check child route
      child_route = all_routes.find { |key, _| key[:path] == "/api/v1/users" }&.last
      expect(child_route[:endpoint].has_after?).to be false
      expect(child_route[:endpoint].has_handler?).to be true
    end
  end

  describe "before and after blocks together" do
    it "executes in correct order: parent before, child before, handler, child after, parent after" do
      execution_order = []

      # Register parent route with before and after blocks
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent filters"
        endpoint.before do |request, response|
          execution_order << :parent_before
        end
        endpoint.after do |request, response|
          execution_order << :parent_after
        end
      end

      # Register child route with before, after, and handler blocks
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.description "Get users"
        endpoint.response 200, type: :array
        endpoint.before do |request, response|
          execution_order << :child_before
        end
        endpoint.after do |request, response|
          execution_order << :child_after
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
      router.call(env)

      # Verify complete execution order
      expect(execution_order).to eq([
        :parent_before,
        :child_before,
        :handler,
        :child_after,
        :parent_after
      ])
    end
  end

  describe "after blocks can modify response" do
    it "allows after blocks to modify response body" do
      Raxon::RouteLoader.register("routes/api/v1/get.rb") do |endpoint|
        endpoint.description "Parent filter that adds metadata"
        endpoint.after do |request, response|
          if response.body.is_a?(Hash)
            response.body[:metadata] = {processed: true}
          end
        end
      end

      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.description "Get users"
        endpoint.response 200, type: :object
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {users: []}
        end
      end

      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
      status, _headers, body = router.call(env)

      expect(status).to eq(200)
      parsed_body = JSON.parse(body.first)
      expect(parsed_body["metadata"]).to eq({"processed" => true})
      expect(parsed_body["users"]).to eq([])
    end

    it "allows after blocks to add response headers" do
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.description "Get users"
        endpoint.response 200, type: :array
        endpoint.after do |request, response|
          response.rack_response["X-Total-Count"] = "42"
          response.rack_response["X-Processing-Complete"] = "true"
        end
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = []
        end
      end

      router = Raxon::Router.new
      env = Rack::MockRequest.env_for("/api/v1/users", method: "GET")
      status, headers, _body = router.call(env)

      expect(status).to eq(200)
      expect(headers["X-Total-Count"]).to eq("42")
      expect(headers["X-Processing-Complete"]).to eq("true")
    end
  end
end
