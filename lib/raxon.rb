require "alba"
require "dry-initializer"
require "dry-schema"
require "json"
require "mustermann"
require "ostruct"
require "pathname"
require "rack"

# Active Support dependencies
require "active_support/core_ext/enumerable"
require "active_support/core_ext/hash"

# Load OpenAPI DSL library
require_relative "raxon/open_api/component"
require_relative "raxon/open_api/endpoint"
require_relative "raxon/open_api/parameter"
require_relative "raxon/open_api/parameters"
require_relative "raxon/open_api/property"
require_relative "raxon/open_api/request_body"
require_relative "raxon/open_api/error"

# Load all OpenApi related files
require_relative "raxon/open_api/dsl"
require_relative "raxon/open_api/request_schema_generator"
require_relative "raxon/open_api/response_schema_generator"

# Load rake tasks automatically
Dir[File.join(__dir__, "openapi-dsl", "tasks", "**", "*.rake")].each { |ext| load ext } if defined?(Rake)

# Load Raxon components
require_relative "raxon/cli"
require_relative "raxon/configuration"
require_relative "raxon/error_handler"
require_relative "raxon/handler_helpers"
require_relative "raxon/instrumentation"
require_relative "raxon/request"
require_relative "raxon/response"
require_relative "raxon/routes"
require_relative "raxon/route_loader"
require_relative "raxon/router"
require_relative "raxon/server"
require_relative "raxon/version"

module Raxon
  class Error < StandardError; end

  # Exception raised when Response#halt is called to stop request processing.
  #
  # This exception is used internally by the framework to implement the halt
  # mechanism. When caught by the Router, it stops execution of remaining
  # before blocks and the handler, and returns the current response.
  #
  # @example
  #   endpoint.before do |request, response|
  #     response.code = :unauthorized
  #     response.body = { error: "Unauthorized" }
  #     response.halt  # Raises HaltException
  #   end
  class HaltException < StandardError
    attr_reader :response

    # Initialize a HaltException with the response to return.
    #
    # @param response [Raxon::Response] The response object to return
    def initialize(response)
      @response = response
      super("Request processing halted")
    end
  end

  @configuration = Configuration.new
  @helpers_loaded = false

  # Access the configuration object
  def self.configuration
    @configuration
  end

  # Configure Raxon with a block
  def self.configure
    yield configuration if block_given?
  end

  # Load all Raxon rake tasks
  def self.load_tasks
    Dir[File.join(__dir__, "tasks", "**", "*.rake")].each { |task| load task } if defined?(Rake)
  end

  # Load handler helpers from the configured helpers_path.
  #
  # This method loads all Ruby files from the configured helpers_path directory
  # and extends HandlerHelpers with any modules defined in those files.
  #
  # Helpers are loaded only once, even if this method is called multiple times.
  # If no helpers_path is configured or the path doesn't exist, this is a no-op.
  #
  # @return [void]
  #
  # @example
  #   Raxon.configure do |config|
  #     config.helpers_path = "app/handlers/concerns"
  #   end
  #   Raxon.load_helpers
  def self.load_helpers
    return if @helpers_loaded
    return unless configuration.helpers_path
    return unless Dir.exist?(configuration.helpers_path)

    Dir.glob(File.join(configuration.helpers_path, "**", "*.rb")).each do |file|
      load file
    end

    @helpers_loaded = true
  end

  # Returns the current environment name.
  #
  # Checks RAXON_ENV first, then falls back to RACK_ENV.
  # Defaults to "development" if neither is set.
  #
  # @return [String] The current environment name
  #
  # @example
  #   ENV["RAXON_ENV"] = "production"
  #   Raxon.env  # => "production"
  def self.env
    ENV["RAXON_ENV"] || ENV["RACK_ENV"] || "development"
  end

  # Returns true if running in development environment.
  #
  # @return [Boolean]
  def self.development?
    env == "development"
  end

  # Returns true if running in production environment.
  #
  # @return [Boolean]
  def self.production?
    env == "production"
  end

  # Returns true if running in test environment.
  #
  # @return [Boolean]
  def self.test?
    env == "test"
  end

  # Returns the root directory of the Raxon application as a Pathname.
  #
  # @return [Pathname] The root directory
  # @raise [Raxon::Error] If root has not been configured
  #
  # @example
  #   Raxon.configure do |config|
  #     config.root = "/path/to/app"
  #   end
  #   Raxon.root  # => #<Pathname:/path/to/app>
  def self.root
    raise Raxon::Error, "Raxon.root has not been configured" unless configuration.root

    Pathname.new(configuration.root)
  end
end
