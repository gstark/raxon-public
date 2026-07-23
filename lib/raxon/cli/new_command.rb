require "fileutils"
require "erb"

module Raxon
  class NewCommand
    attr_reader :project_path, :options, :project_name

    def initialize(project_path, options = {})
      @project_path = File.expand_path(project_path)
      @project_name = File.basename(project_path)
      @options = options
    end

    def execute
      validate_project_path
      create_project_directory
      create_project_structure
      create_gemfile
      create_config_files
      write_gitignore
      initialize_git if !options[:skip_git]
      bundle_install if !options[:skip_bundle]
      print_success_message
    end

    private

    def validate_project_path
      if File.exist?(project_path)
        puts "Error: Directory '#{project_path}' already exists"
        exit 1
      end
    end

    def create_project_directory
      puts "Creating new Raxon project at #{project_path}"
      FileUtils.mkdir_p(project_path)
    end

    def create_project_structure
      puts "Creating project structure..."

      # Create main directories
      create_directories

      # Create essential files
      create_config_ru
      create_rakefile
      create_readme
      create_agents_md
      create_example_routes
      create_spec_files
    end

    def create_directories
      directories = [
        "config",
        "lib",
        "routes/api/v1",
        "spec/fixtures",
        "doc/apidoc",
        "tmp",
        "log"
      ]

      directories.each do |dir|
        FileUtils.mkdir_p(File.join(project_path, dir))
      end
    end

    def create_config_ru
      content = <<~RUBY
        require "bundler/setup"
        require_relative "config/app"

        server = Raxon::Server.new do |app|
          app.use Raxon::ErrorHandler
        end

        run server
      RUBY

      write_file("config.ru", content)
    end

    def create_rakefile
      content = <<~RUBY
        require "bundler/setup"
        require_relative "config/app"

        task default: %w[]

        # Load Raxon rake tasks
        Raxon.load_tasks
      RUBY

      write_file("Rakefile", content)
    end

    def create_readme
      content = <<~MD
        # #{project_name.capitalize}

        A Raxon JSON API project.

        ## Getting Started

        1. Install dependencies:
           ```
           bundle install
           ```

        2. Start the development server:
           ```
           bundle exec raxon server
           ```

        3. View the API documentation:
           ```
           bundle exec rake raxon:openapi:generate
           ```

        ## Project Structure

        - `routes/` - API route definitions organized by path
        - `lib/` - Application code
        - `spec/` - Tests
        - `config/` - Configuration files

        ## Creating Routes

        Routes are automatically mapped from file paths. Create files in `routes/` with the HTTP method as the filename:

        ```
        routes/api/v1/users/get.rb
        routes/api/v1/users/post.rb
        routes/api/v1/users/__id__/get.rb   # GET /api/v1/users/{id}
        ```

        Each route file uses the Raxon DSL:

        ```ruby
        Raxon.route do |endpoint|
          endpoint.description "Get all users"

          endpoint.response 200, type: :array, of: :User do |response|
            # Response definition
          end

          endpoint.handler do |request, response, metadata|
            # Handle the request
            response.code = :ok
            response.body = []
          end
        end
        ```

        ## Testing

        Specs run against the real router, and `conform_to_response_schema`
        validates the response body against the schema declared in the route
        file — so a drifting contract fails the test:

        ```
        bundle exec rspec
        ```

        `spec/health_spec.rb` is a working example to copy.

        ## Documentation

        For more information, visit the [Raxon documentation](https://github.com/gstark/raxon)
      MD

      write_file("README.md", content)
    end

    def create_agents_md
      content = <<~MD
        # AGENTS.md

        Working notes for AI agents (and humans) building on this Raxon API.

        ## The rule that matters

        Every endpoint declares its contract — parameters, request body, and a
        schema per response status — in the same file as its handler. Responses
        are validated against the declared schema at runtime, so an undeclared
        field is a 500, not a silent success. Declare the schema first, then
        write the handler to match.

        ## File → route mapping

        The path comes from the file's location under `routes/`; the filename is
        the HTTP method.

        | File                                  | Route                       |
        | ------------------------------------- | --------------------------- |
        | `routes/api/v1/health/get.rb`          | `GET /api/v1/health`        |
        | `routes/api/v1/users/post.rb`          | `POST /api/v1/users`        |
        | `routes/api/v1/users/__id__/get.rb`    | `GET /api/v1/users/{id}`    |
        | `routes/api/v1/all.rb`                 | every `/api/v1/*` request   |

        Valid filenames: `all`, `get`, `post`, `put`, `patch`, `delete`, `head`,
        `options` (`.rb`). Anything else raises at boot. Path parameters use the
        dunder form `__name__`; the legacy `$name` form also works but trips on
        shell expansion.

        An `all.rb` holds `before`/`after`/`metadata` blocks shared by everything
        below it. With no `handler`, it is middleware only and is not itself a
        route.

        ## The two DSL forms are equivalent

        ```ruby
        Raxon.route do          # zero-arity: evaluated against the endpoint
          description "..."
          response 200, type: :object do
            property :ok, type: :boolean
          end
          handler { |request, response, metadata| response.ok ok: true }
        end

        Raxon.route do |endpoint|   # one-arity: receives the endpoint
          endpoint.description "..."
          endpoint.response(200, type: :object) { |r| r.property :ok, type: :boolean }
          endpoint.handler { |request, response, metadata| response.ok ok: true }
        end
        ```

        Handler, before, after, and metadata blocks all receive
        `(request, response, metadata)`; trailing arguments may be omitted.

        ## Types

        `:string`, `:number`, `:integer`, `:boolean`, `:object`, `:array` (with
        `of:`), `:file`, `:datetime`, `:date`, `:uuid`, `:email`, or an array of
        types for a union. A typo'd type name raises at load with the valid list.

        ## Lifecycle order

        metadata (parent → child) → before (parent → child) → handler → after
        (child → parent). `response.halt` stops the rest immediately. Map domain
        exceptions to statuses with `config.rescue_from` in `config/app.rb`
        rather than rescuing inside each handler.

        ## Verify loop — run these after every change

        ```
        bundle exec raxon routes              # every route loaded, with its handler
        bundle exec rake raxon:openapi:generate  # schemas compile → doc/apidoc/api.json
        bundle exec rspec                     # responses conform to declared schemas
        ```

        `raxon routes` catches bad filenames and load errors, the rake task
        catches invalid schema declarations, and `conform_to_response_schema` in
        specs catches handlers that drifted from their contract. A change is not
        done until all three are green.

        ## Scaffolding

        ```
        bundle exec raxon generate route api/v1/users get post
        bundle exec raxon generate route api/v1/users/__id__ get
        ```
      MD

      write_file("AGENTS.md", content)
    end

    def create_example_routes
      # Create a basic health check route
      ping_route = <<~RUBY
        Raxon.route do |endpoint|
          endpoint.description "Health check endpoint"

          endpoint.response 200, type: :object do |response|
            response.property :success, type: :boolean, description: "true if the API is healthy"
            response.property :timestamp, type: :string, description: "ISO 8601 timestamp"
          end

          endpoint.handler do |request, response, metadata|
            response.code = :ok
            response.body = {
              success: true,
              timestamp: Time.now.iso8601
            }
          end
        end
      RUBY

      write_file("routes/api/v1/health/get.rb", ping_route)
    end

    def create_spec_files
      write_file(".rspec", <<~RSPEC)
        --require spec_helper
        --format documentation
      RSPEC

      write_file("spec/spec_helper.rb", <<~RUBY)
        require "bundler/setup"
        require_relative "../config/app"
        require "raxon/test/rspec"

        RSpec.configure do |config|
          config.include Raxon::Test::Methods

          config.before(:each) do
            Raxon::RouteLoader.reset!
            Raxon::RouteLoader.load!
          end
        end
      RUBY

      write_file("spec/health_spec.rb", <<~RUBY)
        RSpec.describe "health API" do
          it "reports healthy" do
            get "/api/v1/health"

            expect(last_response.status).to eq(200)
            expect(last_response.json["success"]).to be(true)

            # Validates the body against the schema declared in
            # routes/api/v1/health/get.rb
            expect(last_response).to conform_to_response_schema(200)
          end
        end
      RUBY
    end

    def create_gemfile
      content = <<~RUBY
        source "https://rubygems.org"

        gem "raxon"

        group :development, :test do
          gem "puma", "~> 7.0"
          gem "rake"
          gem "rspec", "~> 3.0"
        end
      RUBY

      write_file("Gemfile", content)
    end

    def create_config_files
      # Create main app config
      app_config = <<~RUBY
        require "raxon"

        Raxon.configure do |config|
          # Configure your Raxon application here
        end
      RUBY

      write_file("config/app.rb", app_config)
    end

    def initialize_git
      puts "Initializing Git repository..."
      Dir.chdir(project_path) do
        system("git init")
        system("git add .")
        system("git commit -m 'Initial commit'")
      end
    end

    def write_gitignore
      content = <<~GITIGNORE
        /.bundle/
        /vendor/bundle/
        /log/
        /tmp/
        .env
        .env.local
        .DS_Store
        *.swp
        *.swo
        *~
        .ruby-version
        .ruby-gemset
        doc/apidoc/
      GITIGNORE

      write_file(".gitignore", content)
    end

    def bundle_install
      puts "Installing dependencies..."
      Dir.chdir(project_path) do
        system("bundle install")
      end
    end

    def write_file(filename, content)
      filepath = File.join(project_path, filename)
      FileUtils.mkdir_p(File.dirname(filepath))
      File.write(filepath, content)
    end

    def print_success_message
      puts "\n✓ Project created successfully!"
      puts "\nNext steps:"
      puts "  1. cd #{project_path}"
      puts "  2. bundle exec raxon server"
      puts "\nYour API will be available at http://localhost:9292"
    end
  end
end
