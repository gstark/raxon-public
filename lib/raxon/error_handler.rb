# frozen_string_literal: true

module Raxon
  # Rack middleware for handling unhandled exceptions in API endpoints.
  #
  # This middleware catches any exceptions that occur during request processing
  # and converts them into properly formatted JSON error responses. This prevents
  # raw exception details from being leaked to clients and ensures consistent
  # error response formatting.
  #
  # @example Basic usage
  #   use Raxon::ErrorHandler
  #
  # @example With custom logger
  #   use Raxon::ErrorHandler, logger: Rails.logger
  #
  # @example With custom error handler
  #   use Raxon::ErrorHandler, on_error: ->(request, response, error, env) {
  #     Sentry.capture_exception(error, extra: {
  #       path: request.path,
  #       params: request.params,
  #       user_agent: env['HTTP_USER_AGENT']
  #     })
  #   }
  #
  class ErrorHandler
    # Initialize the error handler middleware.
    #
    # @param app [Object] The Rack application
    # @param logger [Logger, nil] Optional logger for error logging
    # @param on_error [Proc, nil] Optional callback for custom error handling
    #
    # @example
    #   ErrorHandler.new(app, logger: Logger.new($stdout))
    def initialize(app, logger: nil, on_error: nil)
      @app = app
      @logger = logger
      @on_error = on_error
    end

    # Process the request and handle any exceptions.
    #
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response array [status, headers, body]
    def call(env)
      @app.call(env)
    rescue => e
      handle_error(e, env)
    end

    private

    # Handle an exception by logging it and returning a JSON error response.
    #
    # @param error [StandardError] The exception that was raised
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response array with 500 status
    def handle_error(error, env)
      log_error(error, env)
      notify_error(error, env)

      [
        500,
        {"content-type" => "application/json"},
        [JSON.generate({error: "Internal Server Error"})]
      ]
    end

    # Log the error with details.
    #
    # @param error [StandardError] The exception to log
    # @param env [Hash] Rack environment hash
    # @return [void]
    def log_error(error, env)
      return unless @logger

      request = Rack::Request.new(env)
      @logger.error("#{error.class}: #{error.message}")
      @logger.error("Request: #{request.request_method} #{request.path}")
      @logger.error("Backtrace:\n  #{error.backtrace.join("\n  ")}") if error.backtrace
    end

    # Notify external error tracking service if configured.
    #
    # Calls the on_error callback with: (request, response, error, env)
    #
    # @param error [StandardError] The exception to notify
    # @param env [Hash] Rack environment hash
    # @return [void]
    def notify_error(error, env)
      return unless @on_error

      # Get Raxon request/response objects from env
      request = env["raxon.request"]
      response = env["raxon.response"]

      # Call the callback with all four arguments
      @on_error.call(request, response, error, env)
    rescue => e
      # Don't let error notification failures crash the app
      @logger&.error("Error notification failed: #{e.message}")
    end
  end
end
