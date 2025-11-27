require "thor"

module Raxon
  class Command < Thor
    def self.exit_on_failure?
      true
    end

    desc "new PROJECT_PATH", "Create a new Raxon API project"
    option :database, default: "postgresql", desc: "Database adapter (postgresql, sqlite3, mysql2)"
    option :skip_git, type: :boolean, default: false, desc: "Skip Git initialization"
    option :skip_bundle, type: :boolean, default: false, desc: "Skip bundle install"
    def new(project_path)
      require_relative "cli/new_command"
      Raxon::NewCommand.new(project_path, options).execute
    end

    desc "server", "Start the Raxon development server"
    option :port, default: "9292", desc: "Port to run the server on"
    option :host, default: "localhost", desc: "Host to bind the server to"
    def server(*additional_args)
      require_relative "cli/server_command"
      Raxon::ServerCommand.new(options, additional_args).execute
    end

    desc "routes", "Display all registered routes"
    def routes
      require_relative "cli/routes_command"
      Raxon::RoutesCommand.new(options).execute
    end

    desc "version", "Show Raxon version"
    def version
      puts "Raxon #{Raxon::VERSION}"
    end
  end

  # Alias for backwards compatibility
  CLI = Command
end
