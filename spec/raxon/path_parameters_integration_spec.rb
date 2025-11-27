require "spec_helper"

RSpec.describe "Path Parameters Integration" do
  before do
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
  end

  it "extracts path parameters and makes them available in request.params" do
    # Register a route with path parameters
    file_path = "routes/api/v1/users/$id/get.rb"

    Raxon::RouteLoader.register(file_path) do |endpoint|
      endpoint.description "Get user by ID"

      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {
          user_id: request.params[:id],
          type: request.params[:id].class.name
        }
      end
    end

    # Create a rack request
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/api/v1/users/123",
      "rack.input" => StringIO.new
    }

    route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/123")
    expect(route_data).not_to be_nil

    # Simulate what the router does
    env["router.params"] = route_data[:params]

    rack_request = Rack::Request.new(env)
    request = Raxon::Request.new(rack_request, route_data[:endpoint])

    # Verify the parameter is available
    expect(request.params[:id]).to eq("123")
  end

  it "extracts multiple path parameters in order" do
    file_path = "routes/api/v1/orgs/$org_id/projects/$project_id/get.rb"

    Raxon::RouteLoader.register(file_path) do |endpoint|
      endpoint.description "Get project by org and project ID"

      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {
          org_id: request.params[:org_id],
          project_id: request.params[:project_id]
        }
      end
    end

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/api/v1/orgs/acme-corp/projects/website-redesign",
      "rack.input" => StringIO.new
    }

    route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/orgs/acme-corp/projects/website-redesign")
    expect(route_data).not_to be_nil
    expect(route_data[:params]).to eq({
      org_id: "acme-corp",
      project_id: "website-redesign"
    })

    # Simulate what the router does
    env["router.params"] = route_data[:params]

    rack_request = Rack::Request.new(env)
    request = Raxon::Request.new(rack_request, route_data[:endpoint])

    expect(request.params[:org_id]).to eq("acme-corp")
    expect(request.params[:project_id]).to eq("website-redesign")
  end

  it "merges path parameters with query parameters" do
    file_path = "routes/api/v1/users/$id/get.rb"

    Raxon::RouteLoader.register(file_path) do |endpoint|
      endpoint.description "Get user by ID with query params"
      endpoint.handler do |request, response|
        response.code = :ok
        response.body = request.params
      end
    end

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/api/v1/users/456",
      "QUERY_STRING" => "include=posts&limit=10",
      "rack.input" => StringIO.new
    }

    route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/456")
    env["router.params"] = route_data[:params]

    rack_request = Rack::Request.new(env)
    request = Raxon::Request.new(rack_request, route_data[:endpoint])

    # Should have both path and query parameters
    expect(request.params[:id]).to eq("456")
    expect(request.params[:include]).to eq("posts")
    expect(request.params[:limit]).to eq("10")
  end
end
