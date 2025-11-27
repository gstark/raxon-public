# frozen_string_literal: true

module Raxon
  # Rack server application that uses the Router to handle requests.
  #
  # This class provides a Rack-compatible application interface that loads
  # routes from a directory and delegates request handling to the Router.
  #
  # The routes directory is determined by the Raxon configuration, which can be
  # set via environment variable or Raxon.configure block.
  #
  # @example Basic usage
  #   Raxon.configure do |config|
  #     config.routes_directory = "routes"
  #   end
  #
  #   server = Raxon::Server.new
  #   run server
  #
  # @example With middleware
  #   Raxon.configure do |config|
  #     config.routes_directory = "routes"
  #   end
  #
  #   server = Raxon::Server.new do |app|
  #     app.use Rack::Logger
  #     app.use Rack::CommonLogger
  #   end
  #   run server
  #
  class Server
    attr_reader :router

    # Initialize a new Server using the configured routes directory.
    #
    # The routes directory is determined by Raxon.configuration.routes_directory,
    # which can be set via environment variable or Raxon.configure block.
    #
    # @param fallback [#call] Optional Rack application to handle unmatched routes.
    #   If provided, requests that don't match any Raxon route will be delegated
    #   to this application. This allows embedding Raxon in a larger Rack stack
    #   (e.g., as middleware in a Rails application).
    #
    # @yield [self] Optional block for configuring middleware
    #
    # @example Basic usage
    #   Raxon.configure do |config|
    #     config.routes_directory = "routes"
    #   end
    #   server = Raxon::Server.new
    #
    # @example With fallback app
    #   server = Raxon::Server.new(Rails.application)
    def initialize(fallback = nil, **args, &block)
      @middleware = []
      @app = nil

      @router = Router.new(fallback: fallback)

      # Allow middleware configuration via block
      yield self if block_given?

      # Build the app after middleware configuration is complete
      @app = build_app
    end

    # Add middleware to the server stack.
    #
    # When adding Raxon::ErrorHandler, automatically injects the configured on_error
    # callback from Raxon.configuration.on_error if one is set and not already provided.
    #
    # @param middleware [Class] Rack middleware class
    # @param args [Array] Arguments to pass to middleware constructor
    # @param kwargs [Hash] Keyword arguments to pass to middleware constructor
    # @param block [Proc] Block to pass to middleware constructor
    #
    # @example
    #   server.use Rack::Logger
    #   server.use Rack::Session::Cookie, secret: "my_secret"
    #   server.use Raxon::ErrorHandler, logger: Logger.new($stdout)
    def use(new_middleware, *args, **kwargs, &block)
      # Auto-inject configured on_error callback for ErrorHandler
      if new_middleware == Raxon::ErrorHandler && !kwargs.key?(:on_error)
        if Raxon.configuration.on_error
          kwargs = kwargs.merge(on_error: Raxon.configuration.on_error)
        end
      end

      @middleware << [new_middleware, args, kwargs, block]
    end

    # Rack application interface.
    # Delegates to the router after applying any configured middleware.
    # Uses a cached application stack built during initialization for optimal performance.
    #
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response array [status, headers, body]
    def call(env)
      app.call(env)
    end

    private

    attr_reader :app, :middleware

    # Build the Rack application stack with middleware.
    #
    # @return [Object] The Rack application with middleware applied
    def build_app
      # Start with the router as the base application
      new_app = router

      # Apply middleware in reverse order (last added is outermost)
      @middleware.reverse_each do |middleware, args, kwargs, block|
        new_app = if kwargs.empty?
          middleware.new(new_app, *args, &block)
        else
          middleware.new(new_app, *args, **kwargs, &block)
        end
      end

      new_app
    end
  end
end
