require "alba"
require "dry-initializer"
require "ipaddr"
require "dry-schema"
require "json"
require "mustermann"
require "ostruct"
require "pathname"
require "rack"
require "time"

# Load OpenAPI DSL library
require_relative "raxon/open_api/error"
require_relative "raxon/open_api/type_system"
require_relative "raxon/open_api/spec_version"
require_relative "raxon/open_api/property_container"
require_relative "raxon/open_api/deferred_enum"
require_relative "raxon/open_api/component"
require_relative "raxon/open_api/endpoint"
require_relative "raxon/open_api/parameter"
require_relative "raxon/open_api/parameters"
require_relative "raxon/open_api/property"
require_relative "raxon/open_api/request_body"
require_relative "raxon/open_api/security_scheme"

# Load all OpenApi related files
require_relative "raxon/open_api/column_mapper"
require_relative "raxon/open_api/schema_emitter"
require_relative "raxon/open_api/document_builder"
require_relative "raxon/open_api/specification"
require_relative "raxon/open_api/dsl"
require_relative "raxon/uploaded_file"
require_relative "raxon/open_api/property_schema_builder"
require_relative "raxon/open_api/request_body_coercer"
require_relative "raxon/open_api/file_upload_validator"
require_relative "raxon/open_api/request_schema_generator"
require_relative "raxon/open_api/response_schema_generator"

# Load Raxon components
require_relative "raxon/cli"
require_relative "raxon/configuration"
require_relative "raxon/path_containment"
require_relative "raxon/error_handler"
require_relative "raxon/handler_helpers"
require_relative "raxon/instrumentation"
require_relative "raxon/template"
require_relative "raxon/parameter_filter"
require_relative "raxon/request_context"
require_relative "raxon/param_resolver"
require_relative "raxon/limited_input"
require_relative "raxon/request"
require_relative "raxon/response"
require_relative "raxon/outcome"
require_relative "raxon/representation_registry"
require_relative "raxon/effective_endpoint"
require_relative "raxon/endpoint_invocation"
require_relative "raxon/routes"
require_relative "raxon/route_loader"
require_relative "raxon/route_reloader"
require_relative "raxon/route_dsl"
require_relative "raxon/router"
require_relative "raxon/mount"
require_relative "raxon/server"
require_relative "raxon/version"

module Raxon
  class Error < StandardError; end

  # Raised while reading a request body that exceeds the configured
  # max_request_body_size. Caught by the Router and turned into a 413 response;
  # it deliberately bypasses user exception handlers, since an over-limit body
  # is a protocol-level rejection rather than an application error.
  class RequestBodyTooLarge < StandardError; end

  # Exception raised when a response body fails schema validation and
  # response_validation is configured as :raise.
  class ResponseValidationError < Error
    attr_reader :status_code, :errors

    def initialize(status_code:, errors:)
      @status_code = status_code
      @errors = errors
      super("Response validation failed for status #{status_code}")
    end
  end

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
  @representations = RepresentationRegistry.new
  @helpers_loaded = false

  # Access the configuration object
  def self.configuration
    @configuration
  end

  def self.representations
    @representations ||= RepresentationRegistry.new
  end

  def self.register_representation(component, resource, adapter: RepresentationRegistry::AlbaAdapter.new)
    representations.register(component, resource, adapter: adapter)
  end

  # Configure Raxon with a block
  def self.configure
    yield configuration if block_given?
  end

  # Reset all global Raxon state to a clean slate.
  #
  # Intended for test suites — call it from a +before(:each)+ — and for full
  # reloads. Replaces the configuration (see {reset_configuration!}) and empties
  # the route and OpenAPI registries. After this, reconfigure and reload routes
  # as your test needs.
  #
  # @return [void]
  #
  # @example
  #   RSpec.configure do |config|
  #     config.before(:each) do
  #       Raxon.reset!
  #       Raxon.configure { |c| c.routes_directory = "spec/fixtures/routes" }
  #     end
  #   end
  def self.reset!
    reset_configuration!
    RouteLoader.reset!
    OpenApi::DSL.reset!
    @representations = RepresentationRegistry.new
  end

  # Replace the configuration with a fresh instance and forget any loaded
  # handler helpers.
  #
  # Clears every configuration setting along with the accumulated global
  # before/after/around blocks, exception handlers, and not_found handler, and
  # resets the "helpers already loaded" flag so the next {load_helpers} runs
  # again. Leaves the route and OpenAPI registries untouched — use {reset!} for
  # a full reset.
  #
  # @return [void]
  def self.reset_configuration!
    @configuration = Configuration.new
    @helpers_loaded = false
  end

  # Load all Raxon rake tasks
  def self.load_tasks
    require "rake"

    Dir[File.join(__dir__, "tasks", "**", "*.rake")].each { |task| load task }
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

    roots = PathContainment.resolve_roots([configuration.helpers_path])
    Dir.glob(File.join(configuration.helpers_path, "**", "*.rb")).each do |file|
      unless PathContainment.contained?(file, roots)
        raise Raxon::Error, "Refusing to load helper file outside helpers_path: #{file} " \
                            "(it resolves outside the configured helpers tree — check for a symlink)."
      end

      load file
    end

    @helpers_loaded = true
  end

  # Re-load handler helpers from the configured helpers_path.
  #
  # Files are loaded with `load`, so reopened HandlerHelpers methods are
  # redefined in place. Used by RouteReloader in development.
  #
  # @return [void]
  def self.reload_helpers
    @helpers_loaded = false
    load_helpers
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
