require "spec_helper"

RSpec.describe Raxon::RouteLoader do
  before do
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
  end

  describe ".register" do
    it "registers a route from a file path" do
      file_path = "routes/api/v1/users/get.rb"
      block = proc do |endpoint|
        endpoint.description "Get users"
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {users: []}
        end
      end

      Raxon::RouteLoader.register(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/users")
      expect(endpoint.method).to eq("get")
      expect(endpoint.description).to eq("Get users")
    end

    it "registers a route with path parameters" do
      file_path = "routes/api/v1/users/$id/get.rb"
      block = proc do |endpoint|
        endpoint.description "Get user by ID"
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {id: request.params[:id]}
        end
      end

      Raxon::RouteLoader.register(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/123")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/users/{id}")
      expect(endpoint.method).to eq("get")
      expect(route_data[:params]).to eq({id: "123"})
    end

    it "registers a route with multiple path parameters" do
      file_path = "routes/api/v1/users/$user_id/posts/$post_id/get.rb"
      block = proc do |endpoint|
        endpoint.description "Get post by user and post ID"
      end

      Raxon::RouteLoader.register(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/42/posts/99")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/users/{user_id}/posts/{post_id}")
      expect(route_data[:params]).to eq({user_id: "42", post_id: "99"})
    end

    it "raises an error for invalid HTTP method in filename" do
      invalid_file_path = "routes/api/v1/users/invalid_method.rb"

      expect {
        Raxon::RouteLoader.register(invalid_file_path) do
          # no-op
        end
      }.to raise_error(Raxon::Error, /Invalid HTTP method in filename/)
    end

    it "accepts valid HTTP methods (case insensitive)" do
      valid_methods = %w[GET POST PUT PATCH DELETE HEAD OPTIONS]

      valid_methods.each do |method|
        file_path = "routes/api/v1/test/#{method.downcase}.rb"
        expect {
          Raxon::RouteLoader.register(file_path) do
            # no-op
          end
        }.not_to raise_error
      end
    end

    it "accepts 'all' as a valid method" do
      file_path = "routes/api/v1/test/all.rb"
      expect {
        Raxon::RouteLoader.register(file_path) do
          # no-op
        end
      }.not_to raise_error
    end

    it "skips duplicate registration of the same file" do
      file_path = "routes/api/v1/users/get.rb"
      call_count = 0

      block = proc do |endpoint|
        call_count += 1
        endpoint.description "Get users"
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {users: []}
        end
      end

      Raxon::RouteLoader.register(file_path, &block)
      Raxon::RouteLoader.register(file_path, &block)
      Raxon::RouteLoader.register(file_path, &block)

      expect(call_count).to eq(1)
    end

    it "registers all.rb for all HTTP methods" do
      file_path = "routes/api/v1/test/all.rb"
      execution_log = []

      Raxon::RouteLoader.register(file_path) do |endpoint|
        endpoint.description "Catch-all endpoint"
        endpoint.handler do |request, response|
          execution_log << "all.rb executed for #{request.rack_request.request_method}"
          response.code = :ok
          response.body = {message: "all.rb"}
        end
      end

      # Verify that all.rb is registered for each HTTP method
      %w[GET POST PUT PATCH DELETE HEAD OPTIONS].each do |method|
        route_data = Raxon::RouteLoader.routes.find(method, "/api/v1/test")
        expect(route_data).not_to be_nil
        endpoint = route_data[:endpoint]
        expect(endpoint.path).to eq("/api/v1/test")
        expect(endpoint.route_file_path).to end_with("all.rb")
      end
    end

    it "processes all.rb before method-specific handlers in hierarchy" do
      execution_log = []

      # Register an all.rb at /api level
      Raxon::RouteLoader.register("routes/api/all.rb") do |endpoint|
        endpoint.handler do |request, response|
          execution_log << "api/all.rb"
        end
      end

      # Register an all.rb at /api/v1 level
      Raxon::RouteLoader.register("routes/api/v1/all.rb") do |endpoint|
        endpoint.handler do |request, response|
          execution_log << "api/v1/all.rb"
        end
      end

      # Register a GET-specific handler at /api/v1/users level
      Raxon::RouteLoader.register("routes/api/v1/users/get.rb") do |endpoint|
        endpoint.description "Get users"
        endpoint.handler do |request, response|
          execution_log << "api/v1/users/get.rb"
          response.code = :ok
          response.body = {users: []}
        end
      end

      # Retrieve the route and check hierarchy
      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users")
      expect(route_data).not_to be_nil

      # Check that all.rb endpoints come before method-specific ones in the hierarchy
      endpoints = route_data[:endpoints]
      expect(endpoints.length).to be >= 3

      # First should be /api/all.rb
      expect(endpoints[0].route_file_path).to end_with("api/all.rb")

      # Second should be /api/v1/all.rb
      expect(endpoints[1].route_file_path).to end_with("api/v1/all.rb")

      # Third should be /api/v1/users/get.rb
      expect(endpoints[2].route_file_path).to end_with("api/v1/users/get.rb")
    end
  end

  describe ".load!" do
    it "loads all route files from a directory", load_routes: true do
      expect(Raxon::RouteLoader.routes).not_to be_nil
    end

    it "loads all.rb files before method-specific files" do
      # Create a temporary test directory
      require "tmpdir"
      Dir.mktmpdir do |dir|
        # Create directory structure
        FileUtils.mkdir_p(File.join(dir, "api"))
        FileUtils.mkdir_p(File.join(dir, "api/v1"))

        # Create test files
        File.write(File.join(dir, "api/get.rb"), <<~RUBY)
          Raxon::RouteLoader.register(__FILE__) do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/get"} }
          end
        RUBY

        File.write(File.join(dir, "api/all.rb"), <<~RUBY)
          Raxon::RouteLoader.register(__FILE__) do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/all"} }
          end
        RUBY

        File.write(File.join(dir, "api/v1/all.rb"), <<~RUBY)
          Raxon::RouteLoader.register(__FILE__) do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/v1/all"} }
          end
        RUBY

        File.write(File.join(dir, "api/v1/get.rb"), <<~RUBY)
          Raxon::RouteLoader.register(__FILE__) do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/v1/get"} }
          end
        RUBY

        # Configure and load
        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!

        # Track loading order
        load_order = []
        allow(Raxon::RouteLoader).to receive(:load).and_wrap_original do |method, file|
          load_order << File.basename(file)
          method.call(file)
        end

        Raxon::RouteLoader.load!

        # Verify all.rb files are loaded before other files
        all_rb_indices = load_order.each_index.select { |i| load_order[i] == "all.rb" }
        other_indices = load_order.each_index.select { |i| load_order[i] != "all.rb" }

        expect(all_rb_indices.max).to be < other_indices.min if all_rb_indices.any? && other_indices.any?

        # Verify shallower all.rb comes before deeper all.rb
        # (api/all.rb should come before api/v1/all.rb)
        api_all_index = load_order.index { |f| f == "all.rb" }
        api_v1_all_index = load_order.rindex { |f| f == "all.rb" }
        expect(api_all_index).to be < api_v1_all_index if api_all_index && api_v1_all_index && api_all_index != api_v1_all_index
      end
    end
  end

  describe ".register_catchall" do
    it "registers a catchall endpoint" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.description "Handle unmatched routes"
        endpoint.handler do |request, response, metadata|
          response.code = :not_found
          response.body = {error: "Not Found"}
        end
      end

      expect(Raxon::RouteLoader.catchall).not_to be_nil
      expect(Raxon::RouteLoader.catchall.path).to eq("/*")
      expect(Raxon::RouteLoader.catchall.description).to eq("Handle unmatched routes")
    end

    it "allows configuration with responses" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.description "Custom 404"
        endpoint.response 404, type: :object do |response|
          response.property :error, type: :string
          response.property :path, type: :string
        end
        endpoint.handler do |request, response, metadata|
          response.code = :not_found
          response.body = {error: "Not Found", path: request.path}
        end
      end

      catchall = Raxon::RouteLoader.catchall
      expect(catchall).not_to be_nil
      expect(catchall.responses).not_to be_empty
    end

    it "is cleared when reset! is called" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :not_found
        end
      end

      expect(Raxon::RouteLoader.catchall).not_to be_nil

      Raxon::RouteLoader.reset!

      expect(Raxon::RouteLoader.catchall).to be_nil
    end
  end
end
