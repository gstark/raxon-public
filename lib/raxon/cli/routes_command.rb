module Raxon
  class RoutesCommand
    attr_reader :options

    def initialize(options = {})
      @options = options
    end

    def execute
      # Load the Raxon library
      require_relative "../../raxon"

      require_relative "project_loader"
      Raxon::ProjectLoader.load_configuration { configure_from_directory }

      require_relative "../routes_formatter"
      Raxon::RoutesFormatter.display
    end

    private

    def configure_from_directory
      routes_dir = File.join(Dir.pwd, "routes")
      unless Dir.exist?(routes_dir)
        puts "Error: No routes directory found. Please run this command from the root of a Raxon project."
        exit 1
      end
      Raxon.configure do |config|
        config.routes_directory = routes_dir
      end
    end
  end
end
