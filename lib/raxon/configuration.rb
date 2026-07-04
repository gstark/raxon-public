module Raxon
  # Configuration for Raxon applications
  class Configuration
    attr_accessor :routes_directory, :openapi_title, :openapi_description, :openapi_version, :openapi_spec_version, :on_error, :helpers_path, :root, :rails_compatible_instrumentation, :response_validation, :expose_validation_details, :filter_parameters, :trust_proxy_headers, :max_request_body_size, :logger
    alias_method :routes_directories, :routes_directory
    alias_method :routes_directories=, :routes_directory=

    def initialize
      @routes_directory = ENV.fetch("RAXON_ROUTES_DIR", "routes")
      @openapi_title = ENV.fetch("RAXON_OPENAPI_TITLE", "API")
      @openapi_description = ENV.fetch("RAXON_OPENAPI_DESCRIPTION", "")
      @openapi_version = ENV.fetch("RAXON_OPENAPI_VERSION", "1.0")
      # OpenAPI document version to emit: "3.1" (default) or "3.0". Distinct
      # from openapi_version, which is the API's own info.version.
      @openapi_spec_version = ENV.fetch("RAXON_OPENAPI_SPEC_VERSION", "3.1")
      @on_error = nil
      @helpers_path = nil
      @root = nil
      @rails_compatible_instrumentation = false
      @response_validation = production_environment? ? :log : :error_response
      @expose_validation_details = !production_environment?
      # Substrings (case-insensitive) of parameter/header names whose values are
      # redacted before being handed to instrumentation/APM payloads. Matches the
      # spirit of Rails' config.filter_parameters.
      @filter_parameters = %i[password passwd secret token api_key apikey authorization cookie access_token refresh_token private_key credit_card card_number cvv ssn]
      # When false (default), X-Forwarded-For / X-Real-IP are NOT trusted, because
      # any client can forge them. Set true only when Raxon runs behind a proxy
      # you control that overwrites these headers. See Request#remote_ip.
      @trust_proxy_headers = false
      # Maximum request body size in bytes. nil disables the check. When set,
      # requests whose Content-Length exceeds it are rejected before the body is
      # read into memory.
      @max_request_body_size = nil
      @before_blocks = []
      @after_blocks = []
      @around_blocks = []
      @exception_handlers = {}
      @not_found_handler = nil
      # Application logger. When set, Raxon::Server logs every request through
      # Rack::CommonLogger and Raxon::ErrorHandler (when used) logs unhandled
      # exceptions to it.
      @logger = nil
      # Route hot reloading: nil (default) enables it in development only;
      # true/false force it on or off. See RouteReloader.
      @reload_routes = nil
    end

    # Route hot reloading setting; nil means "development only".
    attr_accessor :reload_routes

    # Whether route hot reloading is active, resolving the nil default to
    # "on in development, off elsewhere".
    #
    # @return [Boolean]
    def reload_routes?
      return @reload_routes unless @reload_routes.nil?

      Raxon.development?
    end

    def production_environment?
      (ENV["RAXON_ENV"] || ENV["RACK_ENV"] || "development") == "production"
    end

    private :production_environment?

    # Register a global before block to be executed before every request.
    #
    # Multiple before blocks can be registered and will execute in the order defined.
    # Before blocks execute before route-specific before blocks.
    #
    # @yield [request, response, metadata] Block to execute before each request
    # @yieldparam request [Raxon::Request] The request object
    # @yieldparam response [Raxon::Response] The response object
    # @yieldparam metadata [Hash] The metadata hash
    #
    # @example
    #   Raxon.configure do |config|
    #     config.before do |request, response, metadata|
    #       metadata[:request_start] = Time.now
    #     end
    #   end
    def before(&block)
      @before_blocks << block if block_given?
    end

    # Register a global after block to be executed after every request.
    #
    # Multiple after blocks can be registered and will execute in the order defined.
    # After blocks execute after route-specific after blocks.
    #
    # @yield [request, response, metadata] Block to execute after each request
    # @yieldparam request [Raxon::Request] The request object
    # @yieldparam response [Raxon::Response] The response object
    # @yieldparam metadata [Hash] The metadata hash
    #
    # @example
    #   Raxon.configure do |config|
    #     config.after do |request, response, metadata|
    #       elapsed = Time.now - metadata[:request_start]
    #       response.header "X-Response-Time", elapsed.to_s
    #     end
    #   end
    def after(&block)
      @after_blocks << block if block_given?
    end

    # Register a global around block to wrap request execution.
    #
    # Multiple around blocks can be registered and will nest in the order defined
    # (first registered is outermost). Around blocks wrap the entire request
    # lifecycle including route-specific before/after blocks.
    #
    # The block must call yield to continue request processing.
    #
    # @yield [request, response, metadata] Block to wrap request execution
    # @yieldparam request [Raxon::Request] The request object
    # @yieldparam response [Raxon::Response] The response object
    # @yieldparam metadata [Hash] The metadata hash
    #
    # @example
    #   Raxon.configure do |config|
    #     config.around do |request, response, metadata|
    #       ActiveRecord::Base.connection_pool.with_connection do
    #         yield
    #       end
    #     end
    #   end
    def around(&block)
      @around_blocks << block if block_given?
    end

    # Register an exception handler for a specific exception class.
    #
    # When an exception is raised during request processing, handlers are
    # checked from most specific to least specific (child classes before
    # parent classes). The first matching handler is called.
    #
    # @param exception_class [Class] The exception class to handle
    # @yield [exception, request, response, metadata] Block to handle the exception
    # @yieldparam exception [Exception] The exception that was raised
    # @yieldparam request [Raxon::Request] The request object
    # @yieldparam response [Raxon::Response] The response object
    # @yieldparam metadata [Hash] The metadata hash
    #
    # @example
    #   Raxon.configure do |config|
    #     config.rescue_from(ActiveRecord::RecordNotFound) do |exception, request, response, metadata|
    #       response.code = :not_found
    #       response.body = { error: "Resource not found" }
    #     end
    #   end
    def rescue_from(exception_class, &block)
      raise ArgumentError, "exception_class must be a Class" unless exception_class.is_a?(Class)
      raise ArgumentError, "exception_class must be an Exception subclass" unless exception_class <= Exception

      @exception_handlers[exception_class] = block if block_given?
    end

    # Register a handler for requests that match no route.
    #
    # The block receives a Raxon::Request and a Raxon::Response preloaded with
    # the default 404 status and body; change either as needed. When no handler
    # is registered, the router returns the default JSON 404. For full control
    # over unmatched requests (including running before blocks), define a
    # catchall route instead.
    #
    # @yield [request, response] Block to build the 404 response
    # @yieldparam request [Raxon::Request] The unmatched request
    # @yieldparam response [Raxon::Response] The response to populate
    #
    # @example
    #   Raxon.configure do |config|
    #     config.not_found do |request, response|
    #       response.body = {error: "No such endpoint", path: request.rack_request.path}
    #     end
    #   end
    def not_found(&block)
      @not_found_handler = block if block_given?
    end

    # Returns the registered not-found handler, if any.
    # @return [Proc, nil]
    attr_reader :not_found_handler

    # Returns the array of registered before blocks.
    # @return [Array<Proc>]
    attr_reader :before_blocks

    # Returns the array of registered after blocks.
    # @return [Array<Proc>]
    attr_reader :after_blocks

    # Returns the array of registered around blocks.
    # @return [Array<Proc>]
    attr_reader :around_blocks

    # Returns the hash of registered exception handlers.
    # @return [Hash<Class, Proc>]
    attr_reader :exception_handlers
  end
end
