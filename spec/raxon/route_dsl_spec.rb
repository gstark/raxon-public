require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "Raxon.route" do
  it "registers a route from the calling file with concise endpoint and nested response DSL" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "health"))
      File.write(File.join(dir, "api", "v1", "health", "get.rb"), <<~RUBY)
        Raxon.route do
          description "Health check"

          response 200, type: :object do
            property :success, type: :boolean
          end

          handler do |_request, response|
            response.code = :ok
            response.body = { success: true }
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/health")
      expect(route_data).not_to be_nil

      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/health")
      expect(endpoint.method).to eq("get")
      expect(endpoint.description).to eq("Health check")
      expect(endpoint.responses[200].properties).to include(:success)

      status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/api/v1/health", method: "GET"))
      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq("success" => true)
    end
  end

  it "supports operation metadata" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "posts"))
      File.write(File.join(dir, "api", "v1", "posts", "get.rb"), <<~RUBY)
        Raxon.route do
          summary "List posts"
          operation_id "listPosts"
          tags "Posts", "Public"
          deprecated true
          security :api_key

          response 200, type: :array, of: :object
          handler { |_request, response| response.ok([]) }
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      endpoint = Raxon::RouteLoader.routes.find("GET", "/api/v1/posts")[:endpoint]
      expect(endpoint.summary).to eq("List posts")
      expect(endpoint.operation_id).to eq("listPosts")
      expect(endpoint.tags).to eq(["Posts", "Public"])
      expect(endpoint.deprecated).to be(true)
      expect(endpoint.security).to eq([{api_key: []}])
    end
  end

  it "supports standard error response helpers" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "errors"))
      File.write(File.join(dir, "api", "v1", "errors", "get.rb"), <<~RUBY)
        Raxon.route do
          response 200, type: :object
          validation_error_response
          unauthorized_response
          not_found_response
          error_response 500

          handler { |_request, response| response.ok(success: true) }
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      responses = Raxon::RouteLoader.routes.find("GET", "/api/v1/errors")[:endpoint].responses
      expect(responses.keys).to include(200, 400, 401, 404, 500)
    end
  end

  it "supports endpoint parameter shorthands" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "users", "__id__"))
      File.write(File.join(dir, "api", "v1", "users", "__id__", "get.rb"), <<~RUBY)
        Raxon.route do
          path_param :id, type: :string, description: "User ID"
          query_param :include, type: :string
          header_param :authorization, type: :string, required: true
          cookie_param :session_id, type: :string

          response 200, type: :object do
            property :id, type: :string
          end

          handler do |request, response|
            response.ok id: request.path_params[:id]
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      parameters = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/123")[:endpoint].parameters.parameters
      expect(parameters.map(&:name)).to eq([:id, :include, :authorization, :session_id])
      expect(parameters.map(&:in)).to eq([:path, :query, :header, :cookie])
      expect(parameters.map(&:required)).to eq([true, false, true, false])
    end
  end

  it "supports body as a request_body alias" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "users"))
      File.write(File.join(dir, "api", "v1", "users", "post.rb"), <<~RUBY)
        Raxon.route do
          body type: :object do
            property :name, type: :string
          end

          response 200, type: :object do
            property :name, type: :string
          end

          handler do |request, response|
            response.ok name: request.body_params[:name]
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      request_body = Raxon::RouteLoader.routes.find("POST", "/api/v1/users")[:endpoint].request_body
      expect(request_body).to be_a(Raxon::OpenApi::RequestBody)
      expect(request_body.properties).to include(:name)
    end
  end

  it "supports path parameters and concise parameters DSL" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "users", "__id__"))
      File.write(File.join(dir, "api", "v1", "users", "__id__", "get.rb"), <<~RUBY)
        Raxon.route do
          description "Get user"

          parameters do
            define :id, type: :string, in: :path, description: "User ID"
          end

          response 200, type: :object do
            property :id, type: :string
          end

          handler do |request, response|
            response.code = :ok
            response.body = { id: request.params[:id] }
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/123")
      expect(route_data).not_to be_nil
      expect(route_data[:endpoint].path).to eq("/api/v1/users/{id}")
      expect(route_data[:params]).to eq(id: "123")
      id_parameter = route_data[:endpoint].parameters.parameters.find { |parameter| parameter.name == :id }
      expect(id_parameter.description).to eq("User ID")

      status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/api/v1/users/123", method: "GET"))
      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq("id" => "123")
    end
  end

  it "supports deeply nested zero-arity property blocks" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "nested"))
      File.write(File.join(dir, "api", "v1", "nested", "get.rb"), <<~RUBY)
        Raxon.route do
          response 200, type: :object do
            property :user, type: :object do
              property :name, type: :string
            end
          end

          handler do |_request, response|
            response.code = :ok
            response.body = { user: { name: "Ada" } }
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      user_property = Raxon::RouteLoader.routes.find("GET", "/api/v1/nested")[:endpoint].responses[200].properties[:user]
      expect(user_property.properties).to include(:name)
    end
  end

  it "accepts a bare `property :name` in a route file, and validates it as any type" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "api", "v1", "bare"))
      File.write(File.join(dir, "api", "v1", "bare", "get.rb"), <<~RUBY)
        Raxon.route do
          response 200, type: :object do
            property :notes
          end

          handler do |_request, response|
            response.code = :ok
            response.body = { notes: { any: [1, 2] } }
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      endpoint = Raxon::RouteLoader.routes.find("GET", "/api/v1/bare")[:endpoint]
      expect(endpoint.responses[200].properties[:notes].type).to be_nil
      expect(endpoint.response_schemas[200].call(notes: {any: [1, 2]}).success?).to be true
    end
  end

  it "preserves route-file helper methods loaded in isolation" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "helper"))
      File.write(File.join(dir, "helper", "get.rb"), <<~RUBY)
        def greeting
          "hello"
        end

        Raxon.route do
          response 200, type: :object do
            property :message, type: :string
          end

          handler do |_request, response|
            response.code = :ok
            response.body = { message: greeting }
          end
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/helper", method: "GET"))
      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq("message" => "hello")
    end
  end

  it "can yield the endpoint for callers that want direct access" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "direct"))
      File.write(File.join(dir, "direct", "get.rb"), <<~RUBY)
        Raxon.route do |endpoint|
          endpoint.description "Direct endpoint access"
          endpoint.response 200, type: :object do |response|
            response.property :ok, type: :boolean
          end
          endpoint.handler { |_request, response| response.body = { ok: true } }
        end
      RUBY

      Raxon.configure { |config| config.routes_directory = dir }
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      endpoint = Raxon::RouteLoader.routes.find("GET", "/direct")[:endpoint]
      expect(endpoint.description).to eq("Direct endpoint access")
      expect(endpoint.responses[200].properties).to include(:ok)
    end
  end

  it "requires a block" do
    expect { Raxon.route }.to raise_error(ArgumentError, "Raxon.route requires a block")
  end
end

RSpec.describe Raxon::RouteDSL do
  let(:endpoint) { Raxon::OpenApi::Endpoint.new }
  let(:dsl) { described_class.new(endpoint) }

  it "returns the endpoint request body when called without options" do
    expect(dsl.request_body).to be_nil

    dsl.request_body(type: :object) do
      property :name, type: :string
    end

    expect(dsl.request_body).to be(endpoint.request_body)
    expect(dsl.request_body.properties).to include(:name)
  end

  it "returns the request body through the body alias when called without options" do
    dsl.body(type: :object) do
      property :name, type: :string
    end

    expect(dsl.body).to be(endpoint.request_body)
  end

  it "returns the endpoint parameters when called without a block" do
    dsl.parameters do
      define :id, type: :string, in: :path
    end

    expect(dsl.parameters).to be(endpoint.parameters)
    expect(dsl.parameters.parameters.map(&:name)).to eq([:id])
  end

  it "passes one-arity blocks through to the endpoint unchanged" do
    dsl.response(200, type: :object) do |response|
      response.property :success, type: :boolean
    end

    expect(endpoint.responses[200].properties).to include(:success)
  end

  it "reports and delegates the endpoint API" do
    expect(dsl).to respond_to(:description)

    dsl.description "Health check"

    expect(endpoint.description).to eq("Health check")
  end

  it "raises NoMethodError for methods the endpoint does not support" do
    expect(dsl).not_to respond_to(:not_a_dsl_method)
    expect { dsl.not_a_dsl_method }.to raise_error(NoMethodError)
  end

  it "delegates and reports methods on nested DSL targets" do
    reached = nil

    dsl.response(200, type: :object) do
      property :inner, type: :object do
        reached = respond_to?(:property) && !respond_to?(:not_a_dsl_method)
      end
    end

    expect(reached).to be(true)
  end

  it "raises NameError for unknown methods inside nested blocks" do
    expect do
      dsl.response(200, type: :object) do
        not_a_dsl_method
      end
    end.to raise_error(NameError, /not_a_dsl_method/)
  end
end

RSpec.describe Raxon::RouteDSL, "nested block arity" do
  it "passes one-arity property blocks through inside zero-arity blocks" do
    endpoint = Raxon::OpenApi::Endpoint.new
    dsl = described_class.new(endpoint)

    dsl.response(200, type: :object) do
      property :profile, type: :object do |profile|
        profile.property :bio, type: :string
      end
    end

    expect(endpoint.responses[200].properties[:profile].properties).to include(:bio)
  end
end
