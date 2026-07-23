module Raxon
  # Configuration for Raxon applications
  class Configuration
    # Default cap on request body size (10 MB). Large enough for typical JSON
    # payloads and modest file uploads while bounding how much a single request
    # can read into memory. Applications that accept larger uploads should raise
    # max_request_body_size; set it to nil to disable the check entirely.
    DEFAULT_MAX_REQUEST_BODY_SIZE = 10 * 1024 * 1024
    attr_accessor :routes_directory, :openapi_title, :openapi_description, :openapi_version, :openapi_spec_version, :openapi_type_extensions, :on_error, :helpers_path, :root, :rails_compatible_instrumentation, :response_validation, :expose_validation_details, :filter_parameters, :trusted_proxies, :max_request_body_size, :logger, :schema_adapter, :regexp_timeout, :wrap_error_handler, :path_parameter_defaults, :validation_error_profiles
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
      # Specification extensions applied to every schema emitted with a given
      # DSL type name. Useful for extensions that must appear on introspected
      # columns (from_resource/from_table), where there is no call site to pass
      # extensions: explicitly. Explicit extensions win on key conflicts.
      #
      #   config.openapi_type_extensions = {
      #     datetime: {"x-ts-type" => "Dayjs"},
      #     date: {"x-ts-type" => "Dayjs"}
      #   }
      @openapi_type_extensions = {}
      @on_error = nil
      @helpers_path = nil
      @root = nil
      @rails_compatible_instrumentation = false
      # Response validation runs the endpoint's response schema over every
      # response body it emits. It is opt-in, and off in every environment by
      # default, because it is the most expensive thing Raxon can do per request
      # — roughly 60% of the cost of a small JSON response — and because a
      # response schema is primarily a documentation artifact: an endpoint whose
      # body drifts from its declared schema still answers correctly.
      #
      # Turn it on where the cost buys something. Globally, in the environments
      # where a mismatch is actionable:
      #
      #   Raxon.configure do |config|
      #     config.response_validation = :error_response unless production?
      #   end
      #
      # Or per endpoint, which works regardless of the global setting:
      #
      #   endpoint.validate_response true
      #
      # Modes: :error_response (500 with the errors), :raise
      # (Raxon::ResponseValidationError), :log (warn and answer normally), or
      # false (skip).
      @response_validation = false
      @expose_validation_details = !production_environment?
      # Substrings (case-insensitive) of parameter/header names whose values are
      # redacted before being handed to instrumentation/APM payloads. Matches the
      # spirit of Rails' config.filter_parameters.
      @filter_parameters = %i[password passwd secret token api_key apikey authorization cookie access_token refresh_token private_key credit_card card_number cvv ssn]
      # Per-match timeout (seconds) applied to the regexps Raxon compiles from
      # developer-declared schema patterns and filter_parameters, so a
      # catastrophically-backtracking pattern raises Regexp::TimeoutError instead
      # of pinning a CPU on attacker-controlled input (ReDoS). Scoped to Raxon's
      # own regexps — it does not touch the host app's global Regexp.timeout. Set
      # nil to disable. See docs/security.md.
      @regexp_timeout = 1.0
      # When true (default), Raxon::Server wraps the router in
      # Raxon::ErrorHandler automatically unless one was already added with
      # `use`, so an unhandled exception returns a clean JSON 500 instead of
      # leaking to the app server's default error page. Set false to opt out
      # (e.g. when a host framework or your own middleware handles errors).
      @wrap_error_handler = true
      # Reverse proxies whose X-Forwarded-For entries may be trusted, as an array
      # of IP or CIDR strings (or IPAddr objects), e.g. ["10.0.0.0/8",
      # "127.0.0.1"]. Empty (default) means trust nothing: Request#remote_ip
      # returns the raw connection peer, which a client cannot spoof. When set,
      # remote_ip walks X-Forwarded-For from the right, discarding these trusted
      # hops, and returns the first address that is not one of them.
      @trusted_proxies = []
      # Maximum request body size in bytes (default 10 MB; nil disables the
      # check). A request whose Content-Length exceeds it is rejected before the
      # body is read; a request that lies about or omits Content-Length (e.g. a
      # chunked body) is rejected mid-read once it exceeds the limit. See
      # Raxon::LimitedInput.
      @max_request_body_size = DEFAULT_MAX_REQUEST_BODY_SIZE
      @path_parameter_defaults = nil
      @validation_error_profiles = {}
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
      # Schema introspection adapter for from_resource/from_table. nil (default)
      # auto-detects from the loaded persistence library (ActiveRecord, then
      # Sequel). Set to any object implementing the adapter interface described
      # in OpenApi::SchemaIntrospection to use a custom source.
      @schema_adapter = nil
    end

    # Register a named request-validation HTTP contract. Route ancestors opt
    # into it with +validation_profile+; the body mapper receives the error
    # message and details and must return a JSON-compatible value.
    def validation_error_profile(name, status:, &body)
      @validation_error_profiles[name.to_sym] = {status: status, body: body}.freeze
    end

    # Route hot reloading setting; nil means "development only".
    attr_accessor :reload_routes

    # Whether route hot reloading is active.
    #
    # Hot reloading re-executes route files on change, which is a code-execution
    # surface if the routes directory is ever writable by an untrusted party.
    # It is therefore confined to development: outside development it is always
    # off, even if +reload_routes+ was explicitly set true. Within development
    # the nil default resolves to on, and an explicit true/false is honored.
    #
    # @return [Boolean]
    def reload_routes?
      return false unless Raxon.development?
      return @reload_routes unless @reload_routes.nil?

      true
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
