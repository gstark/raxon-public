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
      create_example_routes
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
        routes/api/v1/users/$id/get.rb
        ```

        Each route file uses the Raxon DSL:

        ```ruby
        Raxon::RouteLoader.register(__FILE__) do |endpoint|
          endpoint.description "Get all users"

          endpoint.response 200, type: :array, of: :User do |response|
            # Response definition
          end

          endpoint.handler do |request, response|
            # Handle the request
            response.code = :ok
            response.body = []
          end
        end
        ```

        ## Documentation

        For more information, visit the [Raxon documentation](https://github.com/gstark/raxon)
      MD

      write_file("README.md", content)
    end

    def create_example_routes
      # Create a basic health check route
      ping_route = <<~RUBY
        Raxon::RouteLoader.register(__FILE__) do |endpoint|
          endpoint.description "Health check endpoint"

          endpoint.response 200, type: :object do |response|
            response.property :success, type: :boolean, description: "true if the API is healthy"
            response.property :timestamp, type: :string, description: "ISO 8601 timestamp"
          end

          endpoint.handler do |request, response|
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

    def create_gemfile
      content = <<~RUBY
        source "https://rubygems.org"

        gem "raxon"

        group :development, :test do
          gem "puma", "~> 6.0"
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
        write_gitignore
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
        Gemfile.lock
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
