module Raxon
  # Configuration for Raxon applications
  class Configuration
    attr_accessor :routes_directory, :openapi_title, :openapi_description, :openapi_version, :on_error, :helpers_path, :root

    def initialize
      @routes_directory = ENV.fetch("RAXON_ROUTES_DIR", "routes")
      @openapi_title = ENV.fetch("RAXON_OPENAPI_TITLE", "API")
      @openapi_description = ENV.fetch("RAXON_OPENAPI_DESCRIPTION", "")
      @openapi_version = ENV.fetch("RAXON_OPENAPI_VERSION", "1.0")
      @on_error = nil
      @helpers_path = nil
      @root = nil
      @before_blocks = []
      @after_blocks = []
      @around_blocks = []
      @exception_handlers = {}
    end

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
