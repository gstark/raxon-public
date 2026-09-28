require "spec_helper"

RSpec.describe Raxon::RouteLoader do
  before do
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
  end

  describe ".define" do
    it "registers a route from a file path" do
      file_path = "routes/api/v1/users/get.rb"
      block = proc do |endpoint|
        endpoint.description "Get users"
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {users: []}
        end
      end

      Raxon::RouteLoader.define(file_path, &block)

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

      Raxon::RouteLoader.define(file_path, &block)

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

      Raxon::RouteLoader.define(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/42/posts/99")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/users/{user_id}/posts/{post_id}")
      expect(route_data[:params]).to eq({user_id: "42", post_id: "99"})
    end

    it "registers a route with dunder-style path parameters" do
      file_path = "routes/api/v1/users/__id__/get.rb"
      block = proc do |endpoint|
        endpoint.description "Get user by ID (dunder syntax)"
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {id: request.params[:id]}
        end
      end

      Raxon::RouteLoader.define(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/456")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/users/{id}")
      expect(endpoint.method).to eq("get")
      expect(route_data[:params]).to eq({id: "456"})
    end

    it "registers a route with multiple dunder-style path parameters" do
      file_path = "routes/api/v1/orgs/__org_id__/projects/__project_id__/get.rb"
      block = proc do |endpoint|
        endpoint.description "Get project by org and project ID"
      end

      Raxon::RouteLoader.define(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/orgs/acme/projects/website")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/orgs/{org_id}/projects/{project_id}")
      expect(route_data[:params]).to eq({org_id: "acme", project_id: "website"})
    end

    it "supports mixing dollar and dunder path parameter styles" do
      file_path = "routes/api/v1/users/$user_id/posts/__post_id__/get.rb"
      block = proc do |endpoint|
        endpoint.description "Mixed parameter styles"
      end

      Raxon::RouteLoader.define(file_path, &block)

      route_data = Raxon::RouteLoader.routes.find("GET", "/api/v1/users/42/posts/99")
      expect(route_data).not_to be_nil
      endpoint = route_data[:endpoint]
      expect(endpoint.path).to eq("/api/v1/users/{user_id}/posts/{post_id}")
      expect(route_data[:params]).to eq({user_id: "42", post_id: "99"})
    end

    it "raises an error for invalid HTTP method in filename" do
      invalid_file_path = "routes/api/v1/users/invalid_method.rb"

      expect {
        Raxon::RouteLoader.define(invalid_file_path) do
          # no-op
        end
      }.to raise_error(Raxon::Error, /Invalid HTTP method in filename/)
    end

    it "accepts valid HTTP methods (case insensitive)" do
      valid_methods = %w[GET POST PUT PATCH DELETE HEAD OPTIONS]

      valid_methods.each do |method|
        file_path = "routes/api/v1/test/#{method.downcase}.rb"
        expect {
          Raxon::RouteLoader.define(file_path) do
            # no-op
          end
        }.not_to raise_error
      end
    end

    it "accepts 'all' as a valid method" do
      file_path = "routes/api/v1/test/all.rb"
      expect {
        Raxon::RouteLoader.define(file_path) do
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

      Raxon::RouteLoader.define(file_path, &block)
      Raxon::RouteLoader.define(file_path, &block)
      Raxon::RouteLoader.define(file_path, &block)

      expect(call_count).to eq(1)
    end

    it "registers all.rb for all HTTP methods" do
      file_path = "routes/api/v1/test/all.rb"
      execution_log = []

      Raxon::RouteLoader.define(file_path) do |endpoint|
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
      Raxon::RouteLoader.define("routes/api/all.rb") do |endpoint|
        endpoint.handler do |request, response|
          execution_log << "api/all.rb"
        end
      end

      # Register an all.rb at /api/v1 level
      Raxon::RouteLoader.define("routes/api/v1/all.rb") do |endpoint|
        endpoint.handler do |request, response|
          execution_log << "api/v1/all.rb"
        end
      end

      # Register a GET-specific handler at /api/v1/users level
      Raxon::RouteLoader.define("routes/api/v1/users/get.rb") do |endpoint|
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

    it "loads route files from dot-prefixed directories" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".well-known"))

        File.write(File.join(dir, ".well-known/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler do |request, response|
              response.code = :ok
              response.body = {path: "/.well-known"}
            end
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        env = Rack::MockRequest.env_for("/.well-known")
        status, _headers, body = Raxon::Router.new.call(env)

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq({"path" => "/.well-known"})
      end
    end

    it "loads route files from multiple routes directories as a union" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        app_routes = File.join(dir, "app_routes")
        engine_routes = File.join(dir, "engine_routes")
        FileUtils.mkdir_p(File.join(app_routes, "api"))
        FileUtils.mkdir_p(File.join(engine_routes, "engine"))

        File.write(File.join(app_routes, "api/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {source: "app"} }
          end
        RUBY

        File.write(File.join(engine_routes, "engine/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {source: "engine"} }
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = [app_routes, engine_routes] }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        expect(Raxon::RouteLoader.routes.find("GET", "/api")).not_to be_nil
        expect(Raxon::RouteLoader.routes.find("GET", "/engine")).not_to be_nil
      end
    end

    it "raises a helpful error when multiple routes directories contain the same endpoint" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        app_routes = File.join(dir, "app_routes")
        engine_routes = File.join(dir, "engine_routes")
        FileUtils.mkdir_p(File.join(app_routes, "api"))
        FileUtils.mkdir_p(File.join(engine_routes, "api"))

        [app_routes, engine_routes].each do |routes_dir|
          File.write(File.join(routes_dir, "api/get.rb"), <<~RUBY)
            Raxon.route do |endpoint|
              endpoint.handler { |request, response| response.body = {} }
            end
          RUBY
        end

        Raxon.configure { |config| config.routes_directory = [app_routes, engine_routes] }
        Raxon::RouteLoader.reset!

        expect { Raxon::RouteLoader.load! }.to raise_error(Raxon::Error, /Route collision for GET \/api/)
      end
    end

    it "uses the longest matching routes directory when configured directories overlap" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        routes = File.join(dir, "routes")
        nested_routes = File.join(routes, "api")
        FileUtils.mkdir_p(File.join(nested_routes, "admin"))

        File.write(File.join(nested_routes, "admin/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {path: endpoint.path} }
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = [routes, nested_routes] }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        expect(Raxon::RouteLoader.routes.find("GET", "/admin")).not_to be_nil
        expect(Raxon::RouteLoader.routes.find("GET", "/api/admin")).to be_nil
      end
    end

    it "deduplicates configured routes directories after expansion" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        routes = File.join(dir, "routes")
        FileUtils.mkdir_p(routes)

        File.write(File.join(routes, "get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {ok: true} }
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = [routes, File.join(routes, ".")] }
        Raxon::RouteLoader.reset!

        loaded_files = []
        allow(Raxon::RouteLoader).to receive(:load_route_in_isolation).and_wrap_original do |method, file|
          loaded_files << file
          method.call(file)
        end

        Raxon::RouteLoader.load!

        expect(loaded_files.size).to eq(1)
        expect(Raxon::RouteLoader.routes.find("GET", "/")).not_to be_nil
      end
    end

    it "raises a helpful error when a route file is outside all configured routes directories" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        routes = File.join(dir, "routes")
        outside = File.join(dir, "outside", "get.rb")
        FileUtils.mkdir_p(routes)
        FileUtils.mkdir_p(File.dirname(outside))

        Raxon.configure { |config| config.routes_directory = routes }
        Raxon::RouteLoader.reset!

        expect {
          Raxon::RouteLoader.define(outside) { |endpoint| endpoint.handler { |_request, response| response.body = {} } }
        }.to raise_error(Raxon::Error, /Route file #{Regexp.escape(outside)} is not inside configured routes_directory: #{Regexp.escape(routes)}/)
      end
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
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/get"} }
          end
        RUBY

        File.write(File.join(dir, "api/all.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/all"} }
          end
        RUBY

        File.write(File.join(dir, "api/v1/all.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/v1/all"} }
          end
        RUBY

        File.write(File.join(dir, "api/v1/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.handler { |request, response| response.body = {msg: "api/v1/get"} }
          end
        RUBY

        # Configure and load
        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!

        # Track loading order
        load_order = []
        allow(Raxon::RouteLoader).to receive(:load_route_in_isolation).and_wrap_original do |method, file|
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

  describe "isolated context" do
    it "allows methods defined in route files to be called from handlers" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.response 200, type: :object do |r|
              r.property :result, type: :string
            end
            endpoint.handler do |request, response|
              response.code = :ok
              response.body = {result: format_greeting("World")}
            end

            private

            def format_greeting(name)
              "Hello, \#{name}!"
            end
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        env = Rack::MockRequest.env_for("/")
        status, _headers, body = Raxon::Router.new.call(env)

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq({"result" => "Hello, World!"})
      end
    end

    it "isolates methods between different route files" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "first"))
        FileUtils.mkdir_p(File.join(dir, "second"))

        # First route defines helper_one
        File.write(File.join(dir, "first/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.response 200, type: :object do |r|
              r.property :result, type: :string
            end
            endpoint.handler do |request, response|
              response.code = :ok
              response.body = {result: helper_one}
            end

            def helper_one
              "from first"
            end
          end
        RUBY

        # Second route defines helper_two (and should NOT have access to helper_one)
        File.write(File.join(dir, "second/get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.response 200, type: :object do |r|
              r.property :result, type: :string
            end
            endpoint.handler do |request, response|
              response.code = :ok
              response.body = {result: helper_two}
            end

            def helper_two
              "from second"
            end
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        # Call first route
        env1 = Rack::MockRequest.env_for("/first")
        status1, _headers1, body1 = Raxon::Router.new.call(env1)
        expect(status1).to eq(200)
        expect(JSON.parse(body1.first)).to eq({"result" => "from first"})

        # Call second route
        env2 = Rack::MockRequest.env_for("/second")
        status2, _headers2, body2 = Raxon::Router.new.call(env2)
        expect(status2).to eq(200)
        expect(JSON.parse(body2.first)).to eq({"result" => "from second"})
      end
    end

    it "shares instance variables between before and handler blocks" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.response 200, type: :object do |r|
              r.property :value, type: :string
            end
            endpoint.before do |request, response|
              @shared_value = "set in before"
            end
            endpoint.handler do |request, response|
              response.code = :ok
              response.body = {value: @shared_value}
            end
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        env = Rack::MockRequest.env_for("/")
        status, _headers, body = Raxon::Router.new.call(env)

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq({"value" => "set in before"})
      end
    end

    it "allows before blocks to use private methods" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "get.rb"), <<~RUBY)
          Raxon.route do |endpoint|
            endpoint.response 200, type: :object do |r|
              r.property :authenticated, type: :boolean
            end
            endpoint.before do |request, response|
              @user = authenticate(request)
            end
            endpoint.handler do |request, response|
              response.code = :ok
              response.body = {authenticated: !@user.nil?}
            end

            private

            def authenticate(request)
              {name: "Test User"}
            end
          end
        RUBY

        Raxon.configure { |config| config.routes_directory = dir }
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!

        env = Rack::MockRequest.env_for("/")
        status, _headers, body = Raxon::Router.new.call(env)

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq({"authenticated" => true})
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

    it "does not appear in the generated OpenAPI document" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :not_found
        end
      end

      expect(Raxon::OpenApi::DSL.endpoints).to be_empty
      expect(Raxon::OpenApi::DSL.to_open_api["paths"]).not_to have_key("/*")
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
