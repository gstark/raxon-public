module Raxon
  class RoutesCommand
    attr_reader :options

    def initialize(options = {})
      @options = options
    end

    def execute
      # Load the Raxon library
      require_relative "../../raxon"

      # Define a stub for 'run' method which is normally provided by rackup
      # We only need the configuration from config.ru, not to actually run the app
      unless Object.method_defined?(:run)
        Object.class_eval do
          def run(_app)
            # Stub method - do nothing
          end
        end
      end

      # If in a Raxon project (has config.ru), try to load it for configuration
      if File.exist?("config.ru")
        begin
          load File.expand_path("config.ru")
        rescue LoadError, StandardError => e
          # If config.ru fails to load, try to infer routes directory
          puts "Warning: Could not load config.ru (#{e.message}), using default configuration"
          configure_from_directory
        end
      else
        # Use default routes directory
        configure_from_directory
      end

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
